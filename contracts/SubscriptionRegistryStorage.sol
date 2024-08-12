// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ISubscriptionRegistryTypes } from "./interfaces/ISubscriptionRegistry.sol";

/**
 * @title SubscriptionRegistryStorage
 * @notice This contract serves as the storage layer.
 * @dev Contains state variables and mappings for managing providers, subscribers, and used signatures.
 */
contract SubscriptionRegistryStorage is ISubscriptionRegistryTypes {
    /// @notice The current number of registered providers.
    uint256 internal _providerCount;

    /// @notice The maximum number of providers that can be registered.
    uint256 internal _maxProviderCount;

    /// @notice The address of the ERC20 token used for payments within the subscription system.
    address internal _token;

    /// @notice The address of the price oracle used for converting token amounts to USD.
    address internal _priceOracle;

    /// @notice A mapping from provider IDs to provider details.
    mapping(uint256 id => Provider) internal _providers;

    /// @notice A mapping from subscriber IDs to subscriber details.
    mapping(uint256 id => Subscriber) internal _subscribers;

    /// @notice A mapping from signature hashes to their usage status to prevent replay attacks.
    mapping(bytes32 signature => bool status) internal _usedSignatures;

    /// @notice A mapping from subscriber to their current active subscriptions.
    mapping(uint256 subscriberId => EnumerableSet.UintSet providers) internal _subscriberActiveSubscriptions;

    /// @notice A mapping from provider to their subscribers last claims.
    mapping(uint256 providerId => mapping(uint256 subscriberId => uint256 lastClaim)) internal _claims;
}
