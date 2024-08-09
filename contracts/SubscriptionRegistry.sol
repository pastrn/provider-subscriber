// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISubscriptionRegistry } from "./interfaces/ISubscriptionRegistry.sol";
import { SubscriptionRegistryStorage } from "./SubscriptionRegistryStorage.sol";

contract SubscriptionRegistry is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    SubscriptionRegistryStorage,
    ISubscriptionRegistry
{
    using SafeERC20 for IERC20;

    uint256 public constant MIN_PROVIDER_FEE_USD = 50; // $50
    uint256 public constant MIN_SUBSCRIBER_DEPOSIT_USD = 100; // $100

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with given addresses and token.
     * @param token_ The address of the ERC20 token.
     * @param priceOracle_ The address with the chainlink price oracle.
     * @param maxProviderCount_ The maximum amount of providers.
     */
    function initialize(address token_, address priceOracle_, uint256 maxProviderCount_) initializer public {
        __Pausable_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        _token = token_;
        _priceOracle = priceOracle_;
        _maxProviderCount = maxProviderCount_;
    }

    /**
     * @notice Pauses the contract, preventing certain functions from being executed.
     * @dev Can only be called by an owner.
     */
    function pause() public onlyOwner  {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing functions to be executed.
     * @dev Can only be called by an owner.
     */
    function unpause() public onlyOwner  {
        _unpause();
    }

    /**
     * @notice Registers a new provider with the specified details.
     * @param providerId The unique identifier for the provider.
     * @param feePerPeriod The fee charged by the provider per subscription period, denominated in tokens.
     * @param periodInSeconds The duration of one subscription period in seconds.
     * @param signature The signature provided to verify the registration details.
     * @dev Reverts if the maximum number of providers has been reached, if the signature is invalid or already used,
     * if the fee is below the minimum allowed, or if a provider with the same ID is already registered.
     */
    function registerProvider(
        uint256 providerId,
        uint256 feePerPeriod,
        uint256 periodInSeconds,
        bytes memory signature
    ) external whenNotPaused {
        if (_providerCount == _maxProviderCount) {
            revert ProviderLimitReached();
        }

        bytes32 signatureHash = keccak256(signature);

        if (_usedSignatures[signatureHash]) {
            revert SignatureAlreadyUsed();
        }
        if (!verifySignature(owner(), msg.sender, providerId, feePerPeriod, periodInSeconds, block.chainid, signature)) {
            revert InvalidSignature();
        }
        if (_getTokenValueInUSD(feePerPeriod) < MIN_PROVIDER_FEE_USD) {
            revert FeeLessThanMinimalAllowed();
        }
        if (_providers[providerId].status != ProviderStatus.Nonexistent) {
            revert ProviderWithSameIdAlreadyRegistered();
        }

        _providers[providerId] = Provider({
            balance: 0,
            feePerPeriod: _safeCastToUint64(feePerPeriod),
            periodInSeconds: _safeCastToUint64(periodInSeconds),
            lastClaim: 0,
            activeSubscribers: 0,
            owner: msg.sender,
            status: ProviderStatus.Active
        });

        _providerCount++;
        _usedSignatures[signatureHash] = true;

        emit ProviderRegistered(providerId, msg.sender, feePerPeriod);
    }

    /**
     * @notice Deletes a registered provider and returns any remaining balance to the provider's owner.
     * @param providerId The unique identifier of the provider to delete.
     * @dev Reverts if the provider does not exist or if the caller is not the owner of the provider.
     * Transfers the remaining balance to the owner before deletion.
     */
    function deleteProvider(uint256 providerId) external whenNotPaused {
        Provider storage provider = _providers[providerId];
        if (provider.status == ProviderStatus.Nonexistent) {
            revert InvalidProviderId();
        }
        if (provider.owner != msg.sender) {
            revert Unauthorized();
        }

        uint256 balance = provider.balance;
        delete _providers[providerId];
        _providerCount--;

        IERC20(_token).safeTransfer(msg.sender, balance);
        emit ProviderDeleted(providerId);
    }

    /**
     * @notice Registers a new subscriber with a specified starting deposit and associates it with a provider.
     * @param subscriberId The unique identifier for the subscriber.
     * @param startingDeposit The initial deposit amount in tokens for the subscription.
     * @param providerId The unique identifier of the provider to subscribe to.
     * @dev Reverts if the subscriber already exists, if the provider is inactive, or if the starting deposit is below the minimum allowed. Transfers the subscription fee to the provider and stores the remaining balance for the subscriber.
     */
    function registerSubscriber(
        uint256 subscriberId,
        uint256 startingDeposit,
        uint256 providerId
    ) external whenNotPaused {
        if (_subscribers[subscriberId].status != SubscriberStatus.Nonexistent) {
            revert SubscriberWithSameIdAlreadyRegistered();
        }

        Provider storage provider = _providers[providerId];

        if (provider.status != ProviderStatus.Active) {
            revert ProviderIsInactive();
        }

        uint256 minRequiredDeposit = provider.feePerPeriod * 2;
        if (_getTokenValueInUSD(startingDeposit) < MIN_SUBSCRIBER_DEPOSIT_USD || startingDeposit < minRequiredDeposit) {
            revert DepositLessThanMinimalAllowed();
        }

        _subscribers[subscriberId] = Subscriber({
            balance: _safeCastToUint64(startingDeposit - provider.feePerPeriod),
            providerId: _safeCastToUint64(providerId),
            startDate: _safeCastToUint64(block.timestamp),
            dueDate: _safeCastToUint64(block.timestamp + provider.periodInSeconds),
            owner: msg.sender,
            status: SubscriberStatus.Active
        });

        provider.balance += provider.feePerPeriod;
        provider.activeSubscribers += 1;

        IERC20(_token).safeTransferFrom(msg.sender, address(this), startingDeposit);

        emit SubscriberRegistered(subscriberId, providerId);
    }

    /**
     * @notice Deletes a subscriber and transfers any free balance back to the subscriber's owner.
     * @param subscriberId The unique identifier of the subscriber to delete.
     * @dev Reverts if the subscriber is not active or if the caller is not the owner of the subscriber.
     * Transfers any free balance to the owner and reallocates reserved balance to the provider.
     */
    function deleteSubscriber(uint256 subscriberId) external whenNotPaused {
        Subscriber storage subscriber = _subscribers[subscriberId];

        if (subscriber.status != SubscriberStatus.Active) {
            revert InvalidSubscriberId();
        }
        if (subscriber.owner != msg.sender) {
            revert Unauthorized();
        }

        uint256 freeBalance = calculateFreeBalance(subscriberId);

        if (freeBalance != 0) {
            uint256 subscriberBalance = subscriber.balance;
            uint256 reservedBalance = subscriberBalance - freeBalance;

            Provider storage provider = _providers[subscriber.providerId];
            provider.balance += _safeCastToUint64(reservedBalance);
            provider.activeSubscribers -= 1;

            IERC20(_token).safeTransfer(msg.sender, freeBalance);
        }

        delete _subscribers[subscriberId];

        emit SubscriberDeleted(subscriberId);
    }

    /**
     * @notice Supplies additional funds to an existing subscriber's balance.
     * @param subscriberId The unique identifier of the subscriber to supply funds to.
     * @param amount The amount of tokens to be added to the subscriber's balance.
     * @dev Reverts if the subscriber is not active or if the caller is not the owner of the subscriber.
     * Transfers the specified amount of tokens from the caller to the contract.
     */
    function supplySubscriber(uint256 subscriberId, uint256 amount) external whenNotPaused {
        Subscriber storage subscriber = _subscribers[subscriberId];
        if (subscriber.status != SubscriberStatus.Active) {
            revert InvalidSubscriberId();
        }
        if (subscriber.owner != msg.sender) {
            revert Unauthorized();
        }

        subscriber.balance += _safeCastToUint64(amount);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundsDeposited(msg.sender, subscriberId, amount);
    }

    /**
     * @notice Claims earnings from a subscriber's balance for a given provider.
     * @param providerId The unique identifier of the provider claiming earnings.
     * @param subscriberId The unique identifier of the subscriber whose balance is used for the claim.
     * @dev Reverts if the provider is not active, if the caller is not the owner of the provider, if the claim is made
     * too early, or if the subscriber's balance is insufficient. If the balance is insufficient, the subscriber's status is paused.
     */
    function claimEarnings(uint256 providerId, uint256 subscriberId) external whenNotPaused {
        Provider storage provider = _providers[providerId];

        if (provider.status != ProviderStatus.Active) {
            revert InvalidProviderId();
        }

        if (provider.owner != msg.sender) {
            revert Unauthorized();
        }

        if (block.timestamp - provider.lastClaim < provider.periodInSeconds) {
            revert EarlyClaim();
        }

        Subscriber storage subscriber = _subscribers[subscriberId];

        if (subscriber.balance < provider.feePerPeriod) {
            subscriber.status = SubscriberStatus.Paused;
            provider.activeSubscribers -= 1;
            emit SubscriptionPaused(subscriberId, providerId);
        } else {
            subscriber.balance -= provider.feePerPeriod;
            provider.balance += _safeCastToUint64(provider.feePerPeriod);
            provider.lastClaim = _safeCastToUint64(block.timestamp);
            emit EarningsClaimed(providerId, block.timestamp, block.timestamp + provider.periodInSeconds);
        }
    }

    /**
     * @notice Withdraws all accumulated earnings for a provider.
     * @param providerId The unique identifier of the provider whose earnings are to be withdrawn.
     * @dev Reverts if the caller is not the owner of the provider.
     * Transfers the provider's balance to the owner's address and resets the provider's balance to zero.
     */
    function withdrawEarnings(uint256 providerId) external whenNotPaused {
        Provider storage provider = _providers[providerId];

        if (provider.owner != msg.sender) {
            revert Unauthorized();
        }

        uint256 amount = provider.balance;
        provider.balance = 0;

        IERC20(_token).safeTransfer(msg.sender, amount);
        emit FundsWithdrawn(providerId, amount, _getTokenValueInUSD(amount));
    }

    /**
     * @notice Updates the status of a provider.
     * @param providerId The unique identifier of the provider whose status is being updated.
     * @param newStatus The new status to assign to the provider.
     * @dev Reverts if the provider is not currently active. Only callable by the contract owner.
     */
    function updateProviderStatus(uint256 providerId, ProviderStatus newStatus) external onlyOwner {
        Provider storage provider = _providers[providerId];

        if (provider.status != ProviderStatus.Active) {
            revert InvalidProviderId();
        }

        provider.status = newStatus;
        emit ProviderStatusUpdated(providerId, newStatus);
    }

    /**
     * @notice Configures the maximum number of providers allowed in the system.
     * @param newAmount The new maximum number of providers.
     * @dev Reverts if the new amount is less than the current number of registered providers. Only callable by the contract owner.
     */
    function configureMaxProviderCount(uint256 newAmount) external onlyOwner {
        if (newAmount < _providerCount) {
            revert InvalidMaxProviderCount();
        }

        _maxProviderCount = newAmount;
        emit MaxProviderCountConfigured(newAmount);
    }

    /**
     * @notice Returns the details of a provider.
     * @param providerId The unique identifier of the provider.
     * @return A struct containing the provider's details.
     */
    function getProvider(uint256 providerId) external view returns (Provider memory) {
        return _providers[providerId];
    }

     /**
     * @notice Returns the details of a subscriber.
     * @param subscriberId The unique identifier of the subscriber.
     * @return A struct containing the subscriber's details.
     */
    function getSubscriber(uint256 subscriberId) external view returns (Subscriber memory) {
        return _subscribers[subscriberId];
    }

     /**
     * @notice Returns the current status of a subscriber.
     * @param subscriberId The unique identifier of the subscriber.
     * @return The current status of the subscriber.
     */
    function getSubscriberStatus(uint256 subscriberId) external view returns (SubscriberStatus) {
        return _subscribers[subscriberId].status;
    }

     /**
     * @notice Previews the current earnings of a provider in tokens.
     * @param providerId The unique identifier of the provider.
     * @return The current balance of the provider in tokens.
     */
    function previewProviderEarnings(uint256 providerId) external view returns (uint256) {
        return _providers[providerId].balance;
    }

     /**
     * @notice Previews the current earnings of a provider in USD.
     * @param providerId The unique identifier of the provider.
     * @return The current balance of the provider in USD.
     */
    function previewProviderEarningsUSD(uint256 providerId) external view returns (uint256) {
        return _getTokenValueInUSD(_providers[providerId].balance);
    }

     /**
     * @notice Returns the address of the token used in the contract.
     * @return The address of the token contract.
     */
    function token() external view returns (address) {
        return _token;
    }

     /**
     * @notice Returns the address of the price oracle used in the contract.
     * @return The address of the price oracle contract.
     */
    function oracle() external view returns (address) {
        return _priceOracle;
    }

     /**
     * @notice Returns the current number of registered providers.
     * @return The number of registered providers.
     */
    function providerCount() external view returns (uint256) {
        return _providerCount;
    }

     /**
     * @notice Returns the maximum number of providers that can be registered.
     * @return The maximum number of providers allowed.
     */
    function maxProviderCount() external view returns (uint256) {
        return _maxProviderCount;
    }

    /**
     * @notice Verifies the validity of a signature.
     * @param signer The address of the signer expected to have signed the message.
     * @param user The address of the user involved in the message.
     * @param providerId The unique identifier of the provider.
     * @param fee The fee amount included in the signed message.
     * @param periodInSeconds The period in seconds included in the signed message.
     * @param chainId The chain ID included in the signed message.
     * @param signature The signature to verify.
     * @return True if the signature is valid and matches the expected signer, otherwise false.
     * @dev Reverts with `InvalidSignatureChainId` if the provided chain ID does not match the current chain ID.
     */
    function verifySignature(
        address signer,
        address user,
        uint256 providerId,
        uint256 fee,
        uint256 periodInSeconds,
        uint256 chainId,
        bytes memory signature
    ) public view returns (bool) {
        if (chainId != block.chainid) {
            revert InvalidSignatureChainId();
        }
        bytes32 messageHash = keccak256(abi.encodePacked(signer, user, providerId, fee, periodInSeconds, chainId));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, signature);

        return recoveredSigner == signer;
    }

    /**
     * @notice Calculates the free balance of a subscriber that can be withdrawn or used.
     * @param subscriberId The unique identifier of the subscriber.
     * @return The free balance available to the subscriber.
     * @dev If the subscriber's due date is in the future, the entire balance is considered free.
     * Otherwise, it deducts the provider's fee per period from the balance, if possible.
     */
    function calculateFreeBalance(uint256 subscriberId) public view returns (uint256) {
        Subscriber storage subscriber = _subscribers[subscriberId];
        Provider storage provider = _providers[subscriber.providerId];

        uint256 totalBalance = subscriber.balance;
        if (subscriber.dueDate > block.timestamp) {
            return totalBalance;
        } else {
            return totalBalance > provider.feePerPeriod ? totalBalance - provider.feePerPeriod : 0;
        }
    }

    /**
     * @notice Converts a token amount to its equivalent value in USD.
     * @param tokenAmount The amount of tokens to convert.
     * @return The equivalent value of the tokens in USD.
     * @dev Uses the latest price data from the price oracle to perform the conversion.
    */
    function _getTokenValueInUSD(uint256 tokenAmount) public view returns (uint256) {
        (,int price,,,) = AggregatorV3Interface(_priceOracle).latestRoundData();
        return tokenAmount * uint256(price) / 10 ** AggregatorV3Interface(_priceOracle).decimals();
    }

    /**
     * @notice Safely casts a `uint256` value to `uint64`.
     * @param value The `uint256` value to cast.
     * @return The `uint64` casted value.
     * @dev Reverts with `IntegerOverflow` if the value is greater than the maximum value of `uint64`.
     */
    function _safeCastToUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) {
            revert IntegerOverflow();
        } else {
            return uint64(value);
        }
    }

    /**
     * @notice Authorizes an upgrade to a new implementation.
     * @param newImplementation The address of the new implementation.
     * @dev Only callable by the contract owner.
     */
    function _authorizeUpgrade(address newImplementation) internal onlyOwner  override {}
}