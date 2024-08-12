// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface ISubscriptionRegistryTypes {
    /**
     * @notice Represents the status of a provider within the subscription system.
     * @dev The status can be one of the following:
     * - `Nonexistent`: The provider does not exist.
     * - `Inactive`: The provider is inactive and not accepting new subscribers.
     * - `Active`: The provider is active and can accept new subscribers.
     */
    enum ProviderStatus {
        Nonexistent,
        Inactive,
        Active
    }

     /**
     * @notice Represents the status of a subscriber within the subscription system.
     * @dev The status can be one of the following:
     * - `Nonexistent`: The subscriber does not exist.
     * - `Active`: The subscriber is active and has an ongoing subscription.
     * - `Paused`: The subscriber's subscription is paused, typically due to insufficient balance.
     */
    enum SubscriberStatus {
        Nonexistent,
        Active,
        Paused
    }

     /**
     * @notice Contains details about a provider in the subscription system.
     * @dev Each `Provider` struct stores information relevant to a provider's subscription terms and current status.
     * @param balance The current balance of the provider in the system.
     * @param feePerPeriod The fee charged by the provider for each subscription period.
     * @param periodInSeconds The duration of each subscription period in seconds.
     * @param owner The address of the provider's owner.
     * @param status The current status of the provider (e.g., active or inactive).
     */
    struct Provider {
        uint64 balance;
        uint64 feePerPeriod;
        uint64 periodInSeconds;
        ProviderStatus status;
        address owner;
    }

     /**
     * @notice Contains details about a subscriber in the subscription system.
     * @dev Each `Subscriber` struct stores information relevant to a subscriber's subscription status and balance.
     * @param balance The current balance of the subscriber.
     * @param owner The address of the subscriber's owner.
     * @param status The current status of the subscriber (e.g., active or paused).
     */
    struct Subscriber {
        uint64 balance;
        address owner;
        SubscriberStatus status;
    }
}

interface ISubscriptionRegistryErrors {
    /**
     * @notice Thrown when the provider limit has been reached and no more providers can be registered.
     */
    error ProviderLimitReached();

     /**
     * @notice Thrown when attempting to set a maximum provider count that is less than the current provider count.
     */
    error InvalidMaxProviderCount();

    /**
     * @notice Thrown when a signature provided for verification is invalid.
     */
    error InvalidSignature();

    /**
     * @notice Thrown when a signature is provided for a different chain ID than the current one.
     */
    error InvalidSignatureChainId();

    /**
     * @notice Thrown when a fee provided by a provider is less than the minimum allowed amount in USD.
     */
    error FeeLessThanMinimalAllowed();

    /**
     * @notice Thrown when a signature has already been used and cannot be reused.
     */
    error SignatureAlreadyUsed();

    /**
     * @notice Thrown when attempting to register a provider with an ID that is already registered.
     */
    error ProviderWithSameIdAlreadyRegistered();

    /**
     * @notice Thrown when the provider ID provided does not correspond to an active or existing provider.
     */
    error InvalidProviderId();

    /**
     * @notice Thrown when a caller attempts to perform an action they are not authorized to execute.
     */
    error Unauthorized();

    /**
     * @notice Thrown when a subscriber's initial deposit is less than the required minimum amount.
     */
    error DepositLessThanMinimalAllowed();

    /**
    * @notice Thrown when attempting to register a subscriber with an ID that is already registered.
    */
    error SubscriberWithSameIdAlreadyRegistered();

    /**
     * @notice Thrown when an action requires a provider to be active, but the provider is inactive.
     */
    error ProviderIsInactive(uint256 providerId);

    /**
     * @notice Thrown when the subscriber ID provided does not correspond to an active or existing subscriber.
     */
    error InvalidSubscriberId();

    /**
     * @notice Thrown when attempting to add a subscription that is already active.
     * @param subscriptionId The unique identifier of the subscription that is already active.
     */
    error SubscriptionAlreadyActive(uint256 subscriptionId);

    /**
     * @notice Thrown when a subscriber does not have sufficient balance to cover the subscription fee.
     */
    error InsufficientBalance();

    /**
     * @notice Thrown when attempting to interact with a subscription that is not active.
     * @param subscriberId The unique identifier of the subscriber whose subscription is inactive.
     */
    error InactiveSubscription(uint256 subscriberId);

    /**
     * @notice Thrown when a provider attempts to claim earnings before the allowed claim period has elapsed.
     */
    error EarlyClaim();

    /**
     * @notice Thrown when a value exceeds the maximum limit for a `uint64` type during a type cast.
     */
    error IntegerOverflow();
}

interface ISubscriptionRegistry is ISubscriptionRegistryTypes, ISubscriptionRegistryErrors {
    /**
     * @notice Emitted when a new provider is registered.
     * @param providerId The unique identifier of the provider.
     * @param owner The address of the owner of the provider.
     * @param fee The fee charged by the provider for each subscription period.
     */
    event ProviderRegistered(uint256 indexed providerId, address indexed owner, uint256 fee);

    /**
     * @notice Emitted when a provider is deleted.
     * @param providerId The unique identifier of the provider that was deleted.
     */
    event ProviderDeleted(uint256 indexed providerId);

    /**
     * @notice Emitted when a new subscriber is registered.
     * @param subscriberId The unique identifier of the subscriber.
     * @param owner The owner of the subscriber.
     */
    event SubscriberRegistered(uint256 indexed subscriberId, address indexed owner);

    /**
     * @notice Emitted when a subscriber adds a subscription to a provider.
     * @param subscriberId The unique identifier of the subscriber.
     * @param providerId The unique identifier of the provider.
     */
    event SubscriptionAdded(uint256 indexed subscriberId, uint256 indexed providerId);

    /**
     * @notice Emitted when a subscriber deletes a subscription from a provider.
     * @param subscriberId The unique identifier of the subscriber.
     * @param providerId The unique identifier of the provider.
     */
    event SubscriptionDeleted(uint256 indexed subscriberId, uint256 indexed providerId);

    /**
     * @notice Emitted when funds are deposited into a subscriber's balance.
     * @param owner The address of the owner who made the deposit.
     * @param subscriberId The unique identifier of the subscriber that was supplied.
     * @param amount The amount of tokens deposited.
     */
    event FundsDeposited(address indexed owner, uint256 indexed subscriberId, uint256 amount);

    /**
     * @notice Emitted when a subscription is paused due to insufficient funds.
     * @param subscriberId The unique identifier of the subscriber whose subscription was paused.
     * @param providerId The unique identifier of the provider to which the subscriber is subscribed.
     */
    event SubscriptionPaused(uint256 indexed subscriberId, uint256 indexed providerId);

    /**
     * @notice Emitted when a provider claims their earnings.
     * @param providerId The unique identifier of the provider claiming earnings.
     * @param claimTimestamp The timestamp when the earnings were claimed.
     * @param nextClaimDate The timestamp when the provider can next claim earnings.
     */
    event EarningsClaimed(uint256 indexed providerId, uint256 subscriberId, uint256 indexed claimTimestamp, uint256 nextClaimDate);

    /**
     * @notice Emitted when a provider withdraws their earnings.
     * @param providerId The unique identifier of the provider making the withdrawal.
     * @param amount The amount of tokens withdrawn.
     * @param amountUSD The equivalent value of the withdrawn tokens in USD.
     */
    event FundsWithdrawn(uint256 indexed providerId, uint256 amount, uint256 amountUSD);

    /**
     * @notice Emitted when a provider's status is updated.
     * @param providerId The unique identifier of the provider whose status was updated.
     * @param newStatus The new status assigned to the provider.
     */
    event ProviderStatusUpdated(uint256 indexed providerId, ProviderStatus newStatus);

    /**
     * @notice Emitted when the maximum number of providers is configured.
     * @param newAmount The new maximum number of providers allowed.
     */
    event MaxProviderCountConfigured(uint256 newAmount);


    /**
     * @notice Registers a new provider with the specified details.
     */
    function registerProvider(uint256 providerId, uint256 feePerPeriod, uint256 periodInSeconds, bytes memory signature) external;

    /**
     * @notice Deletes an existing provider.
     */
    function deleteProvider(uint256 providerId) external;

    /**
     * @notice Registers a new subscriber with an initial deposit.
     */
    function registerSubscriber(uint256 subscriberId, uint256 startingDeposit) external;

    /**
     * @notice Deletes an existing subscriber.
     */
    function deleteSubscription(uint256 subscriberId, uint256 providerId) external;

    /**
     * @notice Adds funds to a subscriber's balance.
     */
    function supplySubscriber(uint256 subscriberId, uint256 amount) external;

    /**
     * @notice Claims earnings for a provider from subscribers.
     */
    function claimEarnings(uint256 providerId, uint256[] memory subscriberIds) external;

    /**
     * @notice Withdraws earnings for a provider.
     */
    function withdrawEarnings(uint256 providerId) external;

    /**
     * @notice Updates the status of an existing provider.
     */
    function updateProviderStatus(uint256 providerId, ProviderStatus newStatus) external;

    /**
     * @notice Returns the details of a specific provider.
     */
    function getProvider(uint256 providerId) external view returns (Provider memory);

    /**
     * @notice Returns the details of a specific subscriber.
     */
    function getSubscriber(uint256 subscriberId) external view returns (Subscriber memory);

    /**
     * @notice Previews the current earnings of a provider in tokens.
     */
    function previewProviderEarnings(uint256 providerId) external view returns (uint256);

    /**
     * @notice Previews the current earnings of a provider in USD.
     */
    function previewProviderEarningsUSD(uint256 providerId) external view returns (uint256);

    /**
     * @notice Calculates the free balance of a specific subscriber.
     */
    function calculateFreeBalance(uint256 subscriberId) external view returns (uint256);
}

