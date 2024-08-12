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
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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
    using EnumerableSet for EnumerableSet.UintSet;

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
     * @notice Registers a new subscriber with a specified starting deposit.
     * @param subscriberId The unique identifier for the subscriber.
     * @param startingDeposit The initial deposit amount in tokens for the subscription.
     * @dev Reverts if the subscriber already exists or if the starting deposit is below the minimum allowed.
     * Transfers the subscription fee to the contract and stores the balance for the subscriber.
     */
    function registerSubscriber(
        uint256 subscriberId,
        uint256 startingDeposit
    ) external whenNotPaused {
        if (_subscribers[subscriberId].status != SubscriberStatus.Nonexistent) {
            revert SubscriberWithSameIdAlreadyRegistered();
        }

        if (_getTokenValueInUSD(startingDeposit) < MIN_SUBSCRIBER_DEPOSIT_USD) {
            revert DepositLessThanMinimalAllowed();
        }

        _subscribers[subscriberId] = Subscriber({
            balance: _safeCastToUint64(startingDeposit),
            status: SubscriberStatus.Active,
            owner: msg.sender
        });

        IERC20(_token).safeTransferFrom(msg.sender, address(this), startingDeposit);

        emit SubscriberRegistered(subscriberId, msg.sender);
    }

    /**
     * @notice Adds a subscription for a subscriber to a specified provider.
     * @param subscriberId The unique identifier of the subscriber.
     * @param providerId The unique identifier of the provider.
     * @dev Reverts if the subscriber is not active, if the caller is not the owner of the subscriber,
     * if the subscription is already active, if the provider is inactive, or if the subscriber has insufficient balance.
     */
    function addSubscription(uint256 subscriberId, uint256 providerId) external whenNotPaused {
        if (_subscribers[subscriberId].status != SubscriberStatus.Active) {
            revert InvalidSubscriberId();
        }
        if (_subscribers[subscriberId].owner != msg.sender) {
            revert Unauthorized();
        }
        if (isActiveSubscription(subscriberId, providerId)) {
            revert SubscriptionAlreadyActive(providerId);
        }

        Provider storage provider = _providers[providerId];

        if (provider.status != ProviderStatus.Active) {
            revert ProviderIsInactive(providerId);
        }
        if (provider.feePerPeriod > _subscribers[subscriberId].balance) {
            revert InsufficientBalance();
        }

        _addSubscription(subscriberId, providerId);
        provider.balance += provider.feePerPeriod;
        _subscribers[subscriberId].balance -= provider.feePerPeriod;
        emit SubscriptionAdded(subscriberId, providerId);
    }

    /**
     * @notice Adds multiple subscriptions for a subscriber to the specified providers.
     * @param subscriberId The unique identifier of the subscriber.
     * @param providerIds An array of unique identifiers of the providers.
     * @dev Reverts if the subscriber is not active, if the caller is not the owner of the subscriber,
     * if any subscription is already active, if any provider is inactive, or if the subscriber has insufficient balance.
     */
    function addSubscriptions(
        uint256 subscriberId,
        uint256[] memory providerIds
    ) external whenNotPaused {
        if (_subscribers[subscriberId].status != SubscriberStatus.Active) {
            revert InvalidSubscriberId();
        }
        if (_subscribers[subscriberId].owner != msg.sender) {
            revert Unauthorized();
        }

        uint256 cost;

        uint256 len = providerIds.length;
        for(uint256 i; i < len;) {
            if (isActiveSubscription(subscriberId, providerIds[i])) {
                revert SubscriptionAlreadyActive(providerIds[i]);
            }

            Provider storage provider = _providers[providerIds[i]];

            if (provider.status != ProviderStatus.Active) {
                revert ProviderIsInactive(providerIds[i]);
            }
            cost += provider.feePerPeriod;
            if (cost > _subscribers[subscriberId].balance) {
                revert InsufficientBalance();
            }

            _addSubscription(subscriberId, providerIds[i]);
            provider.balance += provider.feePerPeriod;
            emit SubscriptionAdded(subscriberId, providerIds[i]);
            ++i;
        }
        _subscribers[subscriberId].balance -= _safeCastToUint64(_subscribers[subscriberId].balance - cost);
    }

    /**
     * @notice Deletes a subscription.
     * @param subscriberId The unique identifier of the subscriber.
     * @param subscriberId The unique identifier of the provider.
     * @dev Reverts if the subscriber is not active or if the caller is not the owner of the subscriber.
     */
    function deleteSubscription(uint256 subscriberId, uint256 providerId) external whenNotPaused {
        if (_subscribers[subscriberId].status != SubscriberStatus.Active) {
            revert InvalidSubscriberId();
        }
        if (_subscribers[subscriberId].owner != msg.sender) {
            revert Unauthorized();
        }

        _removeSubscription(subscriberId, providerId);
        emit SubscriptionDeleted(subscriberId, providerId);
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
     * @notice Claims earnings from multiple subscribers for a specified provider.
     * @param providerId The unique identifier of the provider.
     * @param subscriberIds An array of unique identifiers of the subscribers whose earnings are being claimed.
     * @dev Reverts if the provider is not active, if the caller is not the owner of the provider,
     * if any subscription is inactive, if any claim is made too early, or if a subscriber has insufficient balance.
     * If a subscriber has insufficient balance, their subscription is paused, and the subscription is removed.
     */
    function claimEarnings(uint256 providerId, uint256[] memory subscriberIds) external whenNotPaused {
        Provider storage provider = _providers[providerId];

        if (provider.status != ProviderStatus.Active) {
            revert InvalidProviderId();
        }

        if (provider.owner != msg.sender) {
            revert Unauthorized();
        }

        uint256 totalClaimed;
        uint256 feePerPeriod = provider.feePerPeriod;
        uint256 len = subscriberIds.length;

        for (uint256 i; i < len;) {
            uint256 subscriberId = subscriberIds[i];

            if (!isActiveSubscription(subscriberId, providerId)) {
                revert InactiveSubscription(subscriberId);
            }

            uint256 lastClaim = _claims[providerId][subscriberId];
            if (block.timestamp - lastClaim < provider.periodInSeconds) {
                revert EarlyClaim();
            }

            Subscriber storage subscriber = _subscribers[subscriberId];

            if (subscriber.balance < feePerPeriod) {
                subscriber.status = SubscriberStatus.Paused;
                _removeSubscription(subscriberId, providerId);
                emit SubscriptionPaused(subscriberId, providerId);
            } else {
                subscriber.balance -= _safeCastToUint64(feePerPeriod);
                _claims[providerId][subscriberId] = block.timestamp;
                totalClaimed += feePerPeriod;
                emit EarningsClaimed(providerId, subscriberId, block.timestamp, block.timestamp + provider.periodInSeconds);
            }
            unchecked { ++i; }
        }

        provider.balance += _safeCastToUint64(totalClaimed);
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
        uint256[] memory activeSubscriptions = getSubscriberSubscriptions(subscriberId);

        Subscriber memory subscriber = _subscribers[subscriberId];
        uint256 totalDebt;

        uint256 len = activeSubscriptions.length;
        for(uint256 i; i < len;) {

            Provider memory provider = _providers[activeSubscriptions[i]];

            if (block.timestamp >= _claims[activeSubscriptions[i]][subscriberId] + provider.periodInSeconds) {
                totalDebt += provider.feePerPeriod;
            }
        }
        return subscriber.balance > totalDebt ? subscriber.balance - totalDebt : 0;
    }

    /**
     * @notice Checks if a subscriber has an active subscription to a specific provider.
     * @param subscriberId The unique identifier of the subscriber.
     * @param providerId The unique identifier of the provider.
     * @return True if the subscriber has an active subscription to the provider, otherwise false.
     */
    function isActiveSubscription(uint256 subscriberId, uint256 providerId) public view returns (bool) {
        return _subscriberActiveSubscriptions[subscriberId].contains(providerId);
    }

    /**
     * @notice Retrieves the list of active subscriptions for a specific subscriber.
     * @param subscriberId The unique identifier of the subscriber.
     * @return An array of provider IDs that the subscriber is actively subscribed to.
     */
    function getSubscriberSubscriptions(uint256 subscriberId) public view returns (uint256[] memory) {
        return _subscriberActiveSubscriptions[subscriberId].values();
    }

    /**
     * @notice Adds a subscription for a subscriber to a specific provider.
     * @param subscriberId The unique identifier of the subscriber.
     * @param providerId The unique identifier of the provider.
     * @dev Internal function used to add a provider to the subscriber's list of active subscriptions.
     */
    function _addSubscription(uint256 subscriberId, uint256 providerId) internal {
        _subscriberActiveSubscriptions[subscriberId].add(providerId);
    }

    /**
     * @notice Removes a subscription for a subscriber from a specific provider.
     * @param subscriberId The unique identifier of the subscriber.
     * @param providerId The unique identifier of the provider.
     * @dev Internal function used to remove a provider from the subscriber's list of active subscriptions.
     */
    function _removeSubscription(uint256 subscriberId, uint256 providerId) internal {
        _subscriberActiveSubscriptions[subscriberId].remove(providerId);
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