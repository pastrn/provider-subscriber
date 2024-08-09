import { ethers, upgrades } from "hardhat";
import { expect } from "chai";
import { Contract, ContractFactory } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { TransactionReceipt, TransactionResponse } from "@ethersproject/abstract-provider";
import { time } from "@nomicfoundation/hardhat-network-helpers";

interface Provider {
    balance: number;
    feePerPeriod: number;
    periodInSeconds: number;
    lastClaim: number;
    activeSubscribers: number;
    owner: string
    status: ProviderStatus

    [key: string]: number | string | ProviderStatus;
}

interface Subscriber {
    balance: number;
    providerId: number;
    startDate: number;
    dueDate: number;
    owner: string;
    status: SubscriberStatus

    [key: string]: number | string | SubscriberStatus;
}

enum ProviderStatus {
    Nonexistent = 0,
    Inactive = 1,
    Active = 2
}

enum SubscriberStatus {
    Nonexistent = 0,
    Active = 1,
    Paused = 2
}

describe("Contract 'SubscriptionRegistry'", async () => {
    const STARTING_MAX_PROVIDER_COUNT = 200;
    const DEFAULT_PROVIDER_ID = 322;
    const DEFAULT_FEE = 100;
    const DEFAULT_PERIOD_IN_SECONDS = 3600;
    const HARDHAT_CHAIN_ID = 31337;
    const DEFAULT_SUBSCRIBER_ID = 1337;
    const DEFAULT_STARTING_DEPOSIT = 200;

    const REVERT_ERROR_INVALID_INITIALIZATION = "InvalidInitialization";
    const REVERT_ERROR_OWNABLE_UNAUTHORIZED_ACCOUNT = "OwnableUnauthorizedAccount";
    const REVERT_ERROR_ENFORCED_PAUSE = "EnforcedPause";
    const REVERT_ERROR_EXPECTED_PAUSE = "ExpectedPause";
    const REVERT_ERROR_PROVIDER_LIMIT_REACHED = "ProviderLimitReached";
    const REVERT_ERROR_INVALID_MAX_PROVIDER_COUNT = "InvalidMaxProviderCount";
    const REVERT_ERROR_INVALID_SIGNATURE = "InvalidSignature";
    const REVERT_ERROR_FEE_LESS_THAN_MINIMAL_ALLOWED = "FeeLessThanMinimalAllowed";
    const REVERT_ERROR_SIGNATURE_ALREADY_USED = "SignatureAlreadyUsed";
    const REVERT_ERROR_PROVIDER_WITH_SAME_ID_ALREADY_REGISTERED = "ProviderWithSameIdAlreadyRegistered";
    const REVERT_ERROR_INVALID_PROVIDER_ID = "InvalidProviderId";
    const REVERT_ERROR_UNAUTHORIZED = "Unauthorized";
    const REVERT_ERROR_DEPOSIT_LESS_THAN_MINIMAL_ALLOWED = "DepositLessThanMinimalAllowed";
    const REVERT_ERROR_SUBSCRIBER_WITH_SAME_ID_ALREADY_REGISTERED = "SubscriberWithSameIdAlreadyRegistered";
    const REVERT_ERROR_PROVIDER_IS_INACTIVE = "ProviderIsInactive";
    const REVERT_ERROR_INVALID_SUBSCRIBER_ID = "InvalidSubscriberId";
    const REVERT_ERROR_EARLY_CLAIM = "EarlyClaim";


    const EVENT_NAME_PROVIDER_REGISTERED = "ProviderRegistered";
    const EVENT_NAME_PROVIDER_DELETED = "ProviderDeleted";
    const EVENT_NAME_SUBSCRIBER_REGISTERED = "SubscriberRegistered";
    const EVENT_NAME_SUBSCRIBER_DELETED = "SubscriberDeleted";
    const EVENT_NAME_FUNDS_DEPOSITED = "FundsDeposited";
    const EVENT_NAME_EARNINGS_CLAIMED = "EarningsClaimed";
    const EVENT_NAME_SUBSCRIPTION_PAUSED = "SubscriptionPaused";
    const EVENT_NAME_FUNDS_WITHDRAWN = "FundsWithdrawn";
    const EVENT_NAME_PROVIDER_STATUS_UPDATED = "ProviderStatusUpdated";
    const EVENT_NAME_MAX_PROVIDER_COUNT_CONFIGURED = "MaxProviderCountConfigured";


    let tokenFactory: ContractFactory;
    let aggregatorFactory: ContractFactory;
    let registryFactory: ContractFactory;

    let deployer: HardhatEthersSigner;
    let provider: HardhatEthersSigner;
    let attacker: HardhatEthersSigner;

    let token: Contract;
    let aggregator: Contract;

    let tokenAddress: string;
    let aggregatorAddress: string;

    before(async () => {
        [deployer, provider, attacker] = await ethers.getSigners();
        tokenFactory = await ethers.getContractFactory("TestToken");
        aggregatorFactory = await ethers.getContractFactory("AggregatorMock");
        registryFactory = await ethers.getContractFactory("SubscriptionRegistry");

        token = (await tokenFactory.deploy()) as Contract;
        await token.waitForDeployment;
        token = token.connect(deployer) as Contract;
        tokenAddress = await token.getAddress();

        aggregator = (await aggregatorFactory.deploy()) as Contract;
        await aggregator.waitForDeployment;
        aggregator = aggregator.connect(deployer) as Contract;
        aggregatorAddress = await aggregator.getAddress();
    });

    async function deployRegistry(): Promise<{ registry: Contract }> {
        let registry: Contract = await upgrades.deployProxy(registryFactory, [
            tokenAddress,
            aggregatorAddress,
            STARTING_MAX_PROVIDER_COUNT
        ]);
        await registry.waitForDeployment;
        registry = registry.connect(deployer) as Contract;
        await token.approve(await registry.getAddress(), ethers.MaxUint256);

        return {
            registry
        };
    }

    async function deployRegistryAndRegisterProvider(): Promise<{ registry: Contract }> {
        const { registry } = await deployRegistry();
        const registryConnectedToProvider = registry.connect(provider) as Contract;
        const signature = await createDefaultSignature();
        await registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature);

        return {
            registry
        };
    }

    async function getTx(txResponsePromise: Promise<TransactionResponse>): Promise<TransactionReceipt> {
        const txReceipt = await txResponsePromise;
        return txReceipt.wait();
    }

    async function createSignature(
        signer: HardhatEthersSigner,
        sender: HardhatEthersSigner,
        providerId: number,
        fee: number,
        periodInSeconds: number,
        chainId: number
    ): Promise<string> {
        const message = ethers.solidityPackedKeccak256(
            ["address", "address", "uint256", "uint256", "uint256", "uint256"],
            [signer.address, sender.address, providerId, fee, periodInSeconds, chainId]
        );
        const messageHashBin = ethers.getBytes(message);
        return await signer.signMessage(messageHashBin);
    }

    async function createDefaultSignature(): Promise<string> {
        return await createSignature(deployer, provider, DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, HARDHAT_CHAIN_ID);
    }

    function createDefaultProviderState(): Provider {
        return {
            balance: 0,
            feePerPeriod: DEFAULT_FEE,
            periodInSeconds: DEFAULT_PERIOD_IN_SECONDS,
            lastClaim: 0,
            activeSubscribers: 0,
            owner: provider.address,
            status: ProviderStatus.Active
        }
    }

    async function createDefaultSubscriberState(): Promise<Subscriber> {
        return {
            balance: DEFAULT_STARTING_DEPOSIT - DEFAULT_FEE,
            providerId: DEFAULT_PROVIDER_ID,
            startDate: await time.latest(),
            dueDate: await time.latest() + DEFAULT_PERIOD_IN_SECONDS,
            owner: deployer.address,
            status: SubscriberStatus.Active
        }
    }

    function compareSubscriberState(actualState: Subscriber, expectedState: Subscriber) {
        Object.keys(expectedState).forEach(property => {
            expect(actualState[property]).to.eq(
                expectedState[property],
                `Mismatch in the "${property}" property of the subscriber state`
            );
        });
    }

    function compareProviderState(actualState: Provider, expectedState: Provider) {
        Object.keys(expectedState).forEach(property => {
            expect(actualState[property]).to.eq(
                expectedState[property],
                `Mismatch in the "${property}" property of the provider state`
            );
        });
    }

    describe("Functions 'initialize()' and '_authorizeUpgrade'", async () => {
        it("Initializer configures contract as expected", async () => {
            const { registry } = await loadFixture(deployRegistry);

            expect(await registry.token()).to.eq(tokenAddress);
            expect(await registry.oracle()).to.eq(aggregatorAddress);
            expect(await registry.maxProviderCount()).to.eq(STARTING_MAX_PROVIDER_COUNT);
            expect(await registry.owner()).to.eq(deployer.address);
        });

        it("Initializer is reverted if called second time", async () => {
            const { registry } = await loadFixture(deployRegistry);

            await expect(registry.initialize(tokenAddress, aggregatorAddress, STARTING_MAX_PROVIDER_COUNT))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_INITIALIZATION);
        });

        it("'upgradeToAndCall()' executes as expected", async () => {
            const { registry } = await loadFixture(deployRegistry);

            const contractAddress = await registry.getAddress();
            const oldImplementationAddress = await upgrades.erc1967.getImplementationAddress(contractAddress);
            const newImplementation = await registryFactory.deploy();
            await newImplementation.waitForDeployment();
            const expectedNewImplementationAddress = await newImplementation.getAddress();

            await getTx(registry.upgradeToAndCall(expectedNewImplementationAddress, "0x"));

            const actualNewImplementationAddress = await upgrades.erc1967.getImplementationAddress(contractAddress);
            expect(actualNewImplementationAddress).to.eq(expectedNewImplementationAddress);
            expect(actualNewImplementationAddress).not.to.eq(oldImplementationAddress);
        });

        it("'upgradeToAndCall()' is reverted if the caller is not the owner", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const registryConnectedToAttacker = registry.connect(attacker) as Contract;

            await expect(registryConnectedToAttacker.upgradeToAndCall(attacker.address, "0x"))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_OWNABLE_UNAUTHORIZED_ACCOUNT)
                .withArgs(attacker.address);
        });
    });

    describe("Function 'pause()'", async () => {
        it("Executes as expected and pauses contract", async () => {
            const { registry } = await loadFixture(deployRegistry);

            expect(await registry.paused()).to.eq(false);
            await registry.pause();
            expect(await registry.paused()).to.eq(true);
        });

        it("Is reverted if the caller does not have pauser role", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const registryConnectedToAttacker = registry.connect(attacker) as Contract;

            await expect(registryConnectedToAttacker.pause())
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_OWNABLE_UNAUTHORIZED_ACCOUNT)
                .withArgs(attacker.address);
        });

        it("Is reverted if the contract is paused", async () => {
            const { registry } = await loadFixture(deployRegistry);

            await registry.pause();
            expect(await registry.paused()).to.eq(true);
            await expect(registry.pause()).to.be.revertedWithCustomError(registry, REVERT_ERROR_ENFORCED_PAUSE);
        });
    });

    describe("Function 'unpause()'", async () => {
        it("Executes as expected and unpauses contract", async () => {
            const { registry } = await loadFixture(deployRegistry);

            await registry.pause();
            expect(await registry.paused()).to.eq(true);

            await registry.unpause();
            expect(await registry.paused()).to.eq(false);
        });

        it("Is reverted if the caller does not have pauser role", async () => {
            const { registry } = await loadFixture(deployRegistry);
            await registry.pause();
            const registryConnectedToAttacker = registry.connect(attacker) as Contract;

            await expect(registryConnectedToAttacker.unpause())
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_OWNABLE_UNAUTHORIZED_ACCOUNT)
                .withArgs(attacker.address);
        });

        it("Is reverted if the contract is not paused", async () => {
            const { registry } = await loadFixture(deployRegistry);

            expect(await registry.paused()).to.eq(false);
            await expect(registry.unpause()).to.be.revertedWithCustomError(registry, REVERT_ERROR_EXPECTED_PAUSE);
        });
    });

    describe("Function 'registerProvider()'", async () => {
        it("Executes as expected and emits correct event", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const registryConnectedToProvider = registry.connect(provider) as Contract;
            const signature = await createDefaultSignature();

            const providerCountBefore = await registry.providerCount();
            const expectedProviderState = createDefaultProviderState();

            await expect(
                registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.emit(registry, EVENT_NAME_PROVIDER_REGISTERED)
                .withArgs(DEFAULT_PROVIDER_ID, provider.address, DEFAULT_FEE);
            const createdProvider: Provider = await registry.getProvider(DEFAULT_PROVIDER_ID);

            expect(await registry.providerCount()).to.eq(Number(providerCountBefore) + 1);
            await compareProviderState(createdProvider, expectedProviderState);
        });

        it("Is reverted if the contract is paused", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const signature = await createDefaultSignature();
            await registry.pause();

            await expect(registry.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_ENFORCED_PAUSE);
        });

        it("Is reverted if the signature is invalid", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const signature = await createDefaultSignature();

            await expect(registry.registerProvider(DEFAULT_PROVIDER_ID + 1, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_SIGNATURE);
        });

        it("Is reverted if the caller is not the signed caller", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const signature = await createDefaultSignature();

            await expect(registry.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_SIGNATURE);
        });

        it("Is reverted if the signature is already used", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const registryConnectedToProvider = registry.connect(provider) as Contract;
            const signature = await createDefaultSignature();

            await registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature);

            await expect(registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_SIGNATURE_ALREADY_USED);
        });

        it("Is reverted if the fee is less than minimal allowed", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const registryConnectedToProvider = registry.connect(provider) as Contract;
            const signature = await createSignature(
                deployer,
                provider,
                DEFAULT_PROVIDER_ID,
                0, // fee
                DEFAULT_PERIOD_IN_SECONDS,
                HARDHAT_CHAIN_ID
            );

            await expect(registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, 0, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_FEE_LESS_THAN_MINIMAL_ALLOWED);
        });

        it("Is reverted if the provider with same id is already registered", async () => {
            const { registry } = await loadFixture(deployRegistry);
            const registryConnectedToProvider = registry.connect(provider) as Contract;
            let signature = await createDefaultSignature();
            await registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature);

            signature = await createSignature(
                deployer,
                provider,
                DEFAULT_PROVIDER_ID,
                DEFAULT_FEE + 1,
                DEFAULT_PERIOD_IN_SECONDS,
                HARDHAT_CHAIN_ID
            );

            await expect(registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE + 1, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_PROVIDER_WITH_SAME_ID_ALREADY_REGISTERED);
        });

        it("Is reverted if the limit of providers reached", async () => {
            const { registry } = await loadFixture(deployRegistry);

            await registry.configureMaxProviderCount(0);

            const registryConnectedToProvider = registry.connect(provider) as Contract;
            let signature = await createDefaultSignature();
            await expect(registryConnectedToProvider.registerProvider(DEFAULT_PROVIDER_ID, DEFAULT_FEE, DEFAULT_PERIOD_IN_SECONDS, signature))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_PROVIDER_LIMIT_REACHED);
        });
    });

    describe("Function 'deleteProvider()'", async () => {
       it("Executes as expected and emits correct event", async () => {
           const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
           const registryConnectedToProvider = registry.connect(provider) as Contract;

           await expect(registryConnectedToProvider.deleteProvider(DEFAULT_PROVIDER_ID))
               .to.emit(registry, EVENT_NAME_PROVIDER_DELETED)
               .withArgs(DEFAULT_PROVIDER_ID);

           const expectedProviderState: Provider = {
               balance: 0,
               feePerPeriod: 0,
               periodInSeconds: 0,
               lastClaim: 0,
               activeSubscribers: 0,
               owner: ethers.ZeroAddress,
               status: ProviderStatus.Nonexistent
           }

           const actualState: Provider = await registry.getProvider(DEFAULT_PROVIDER_ID);

           compareProviderState(actualState, expectedProviderState);

           expect(await registry.previewProviderEarningsUSD(DEFAULT_PROVIDER_ID)).to.eq(0);
           expect(await registry.previewProviderEarnings(DEFAULT_PROVIDER_ID)).to.eq(0);
       });

       it("Is reverted if the provider with such does not exist", async () => {
           const { registry } = await loadFixture(deployRegistry);

           await expect(registry.deleteProvider(DEFAULT_PROVIDER_ID))
               .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_PROVIDER_ID);
       });

        it("Is reverted if the caller is not the owner of the provider", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
            const registryConnectedToAttacker = await registry.connect(attacker) as Contract;

            await expect(registryConnectedToAttacker.deleteProvider(DEFAULT_PROVIDER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_UNAUTHORIZED);
        });

        it("Is reverted if the contract is paused", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
            await registry.pause();

            await expect(registry.deleteProvider(DEFAULT_PROVIDER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_ENFORCED_PAUSE);
        });
    });

    describe("Function 'registerSubscriber()'", async () => {
        it("Executes as expected and emits the correct event", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);

            const tx = await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);
            const actualSubscriberState: Subscriber = await registry.getSubscriber(DEFAULT_SUBSCRIBER_ID);
            const expectedSubscriberState: Subscriber = await createDefaultSubscriberState();

            await expect(tx)
                .to.emit(registry, EVENT_NAME_SUBSCRIBER_REGISTERED)
                .withArgs(DEFAULT_SUBSCRIBER_ID, DEFAULT_PROVIDER_ID);

            await expect(tx).to.changeTokenBalances(
                token,
                [deployer, registry],
                [-DEFAULT_STARTING_DEPOSIT, +DEFAULT_STARTING_DEPOSIT]
            );

            compareSubscriberState(actualSubscriberState, expectedSubscriberState);
        });

        it("Is reverted if the contract is paused", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
            await registry.pause();

            await expect(registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_ENFORCED_PAUSE);
        });

        it("Is reverted if the subscriber with same id is already registered", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
            await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);

            await expect(registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_SUBSCRIBER_WITH_SAME_ID_ALREADY_REGISTERED);
        });

        it("Is reverted if the provider with the selected id is not active", async () => {
            const { registry } = await loadFixture(deployRegistry);

            await expect(registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_PROVIDER_IS_INACTIVE);
        });

        it("Is reverted if the starting deposit is less than allowed one", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);

            await expect(registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, 0, DEFAULT_PROVIDER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_DEPOSIT_LESS_THAN_MINIMAL_ALLOWED);

            await expect(registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, (DEFAULT_FEE * 2) - 1, DEFAULT_PROVIDER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_DEPOSIT_LESS_THAN_MINIMAL_ALLOWED);
        })
    });

    describe("Function 'deleteSubscriber()'", async () => {
        it("Executes as expected and emits correct event", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
            await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);

            const tx = await registry.deleteSubscriber(DEFAULT_SUBSCRIBER_ID);

            await expect(tx)
                .to.emit(registry, EVENT_NAME_SUBSCRIBER_DELETED)
                .withArgs(DEFAULT_SUBSCRIBER_ID);

            await expect(tx)
                .to.changeTokenBalances(
                    token,
                    [registry, deployer],
                    [-DEFAULT_STARTING_DEPOSIT+DEFAULT_FEE, +DEFAULT_STARTING_DEPOSIT-DEFAULT_FEE]
                );

            const expectedSubscriberState: Subscriber = {
                balance: 0,
                providerId: 0,
                startDate: 0,
                dueDate: 0,
                owner: ethers.ZeroAddress,
                status: SubscriberStatus.Nonexistent
            }

            const actualSubscriberState: Subscriber = await registry.getSubscriber(DEFAULT_SUBSCRIBER_ID);

            compareSubscriberState(actualSubscriberState, expectedSubscriberState);

            expect(await registry.calculateFreeBalance(DEFAULT_SUBSCRIBER_ID)).to.eq(0);
        });

        it("Is reverted if subscriber with provided id is not active", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);

            await expect(registry.deleteSubscriber(DEFAULT_SUBSCRIBER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_SUBSCRIBER_ID);

        });

        it("Is reverted if the caller is not the owner of the subscriber", async () => {
            const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
            await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);
            const registryConnectedToAttacker = await registry.connect(attacker) as Contract;

            await expect(registryConnectedToAttacker.deleteSubscriber(DEFAULT_SUBSCRIBER_ID))
                .to.be.revertedWithCustomError(registry, REVERT_ERROR_UNAUTHORIZED);

        });

        describe("Function 'supplySubscriber()'", async () => {
            it("Executes as expected and emits correct event", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);

                const oldFreeBalance: number = Number(await registry.calculateFreeBalance(DEFAULT_SUBSCRIBER_ID));

                const tx = await registry.supplySubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_FEE);

                await expect(tx)
                    .to.emit(registry, EVENT_NAME_FUNDS_DEPOSITED)
                    .withArgs(deployer.address, DEFAULT_SUBSCRIBER_ID, DEFAULT_FEE);

                await expect(tx)
                    .to.changeTokenBalances(
                        token,
                        [registry, deployer],
                        [+DEFAULT_FEE, -DEFAULT_FEE]
                    );

                expect(Number(await registry.calculateFreeBalance(DEFAULT_SUBSCRIBER_ID))).to.eq(oldFreeBalance + DEFAULT_FEE);
            });

            it("Is reverted if the contract is paused", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                await registry.pause();

                await expect(registry.supplySubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_ENFORCED_PAUSE);
            });

            it("Is reverted if the subscriber is not active", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);

                await expect(registry.supplySubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_SUBSCRIBER_ID);
            });

            it("Is reverted if caller is not the subscriber owner", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);
                const registryConnectedToAttacker = await registry.connect(attacker) as Contract;

                await expect(registryConnectedToAttacker.supplySubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_UNAUTHORIZED);
            });
        });

        describe("Function 'claimEarnings()'", async () => {
            it("Executes as expected if subscriber balance is sufficient", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);
                const registryConnectedToProvider = await registry.connect(provider) as Contract;

                await time.increase(DEFAULT_PERIOD_IN_SECONDS + 1);

                const tx = await registryConnectedToProvider.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID);
                const timestamp = await time.latest();

                await expect(tx)
                    .to.emit(registry, EVENT_NAME_EARNINGS_CLAIMED)
                    .withArgs(DEFAULT_PROVIDER_ID, timestamp, timestamp + DEFAULT_PERIOD_IN_SECONDS);

                const subscriptionStatus:SubscriberStatus = await registry.getSubscriberStatus(DEFAULT_SUBSCRIBER_ID);
                await expect(subscriptionStatus).to.eq(SubscriberStatus.Active);
            });

            it("Executes as expected if subscriber balance is insufficient", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);
                const registryConnectedToProvider = await registry.connect(provider) as Contract;

                await time.increase(DEFAULT_PERIOD_IN_SECONDS + 1);

                await registryConnectedToProvider.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID);
                await time.increase(DEFAULT_PERIOD_IN_SECONDS + 1);

                await expect(registryConnectedToProvider.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID))
                    .to.emit(registry, EVENT_NAME_SUBSCRIPTION_PAUSED)
                    .withArgs(DEFAULT_SUBSCRIBER_ID, DEFAULT_PROVIDER_ID)
                    .and.not.to.emit(registry, EVENT_NAME_EARNINGS_CLAIMED)

                const subscriptionStatus:SubscriberStatus = await registry.getSubscriberStatus(DEFAULT_SUBSCRIBER_ID);
                await expect(subscriptionStatus).to.eq(SubscriberStatus.Paused);
            });

            it("Is reverted if the contract is paused", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                await registry.pause();

                await expect(registry.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_ENFORCED_PAUSE);
            });

            it("Is reverted if the provider is not active", async () => {
                const { registry } = await loadFixture(deployRegistry);

                await expect(registry.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_PROVIDER_ID);
            });

            it("Is reverted if the caller is not provider owner", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                const registryConnectedToAttacker = await registry.connect(attacker) as Contract;

                await expect(registryConnectedToAttacker.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_UNAUTHORIZED);
            });

            it("Is reverted if the claim period did not pass", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                const registryConnectedToProvider = await registry.connect(provider) as Contract;
                await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);

                await time.increase(DEFAULT_PERIOD_IN_SECONDS);
                await registryConnectedToProvider.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID);

                await expect(registryConnectedToProvider.claimEarnings(DEFAULT_PROVIDER_ID, DEFAULT_SUBSCRIBER_ID))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_EARLY_CLAIM);
            });
        });

        describe("Function 'withdrawEarnings()'", async () => {
           it("Executes as expected and emits correct event", async () => {
               const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
               const registryConnectedToProvider = await registry.connect(provider) as Contract;
               await registry.registerSubscriber(DEFAULT_SUBSCRIBER_ID, DEFAULT_STARTING_DEPOSIT, DEFAULT_PROVIDER_ID);

               const earningsUSD = await registry.previewProviderEarningsUSD(DEFAULT_PROVIDER_ID);

               const tx = registryConnectedToProvider.withdrawEarnings(DEFAULT_PROVIDER_ID);

               await expect(tx)
                   .to.emit(registry, EVENT_NAME_FUNDS_WITHDRAWN)
                   .withArgs(DEFAULT_PROVIDER_ID, DEFAULT_FEE, earningsUSD);

               await expect(tx)
                   .to.changeTokenBalances(
                       token,
                       [registry, provider],
                       [-DEFAULT_FEE, +DEFAULT_FEE]
                   );

               expect(await registry.previewProviderEarningsUSD(DEFAULT_PROVIDER_ID)).to.eq(0);
               expect(await registry.previewProviderEarnings(DEFAULT_PROVIDER_ID)).to.eq(0);
           });

           it("Is reverted if the caller is not the owner of the provider", async() => {
               const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
               const registryConnectedToAttacker = await registry.connect(attacker) as Contract;

               await expect(registryConnectedToAttacker.withdrawEarnings(DEFAULT_PROVIDER_ID))
                   .to.be.revertedWithCustomError(registry, REVERT_ERROR_UNAUTHORIZED);
           });

            it("Is reverted if the contract is paused", async() => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);
                await registry.pause();

                await expect(registry.withdrawEarnings(DEFAULT_PROVIDER_ID))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_ENFORCED_PAUSE);
            });
        });

        describe("Function 'updateProviderStatus()'", async () => {
            it("Executes as expected and emits correct event", async () => {
                const { registry } = await loadFixture(deployRegistryAndRegisterProvider);

                await expect(registry.updateProviderStatus(DEFAULT_PROVIDER_ID, ProviderStatus.Inactive))
                    .to.emit(registry, EVENT_NAME_PROVIDER_STATUS_UPDATED)
                    .withArgs(DEFAULT_PROVIDER_ID, ProviderStatus.Inactive);
            });

            it("Is reverted if the caller is not the owner", async () => {
                const { registry } = await loadFixture(deployRegistry);
                const registryConnectedToAttacker = await registry.connect(attacker) as Contract;

                await expect(registryConnectedToAttacker.updateProviderStatus(DEFAULT_PROVIDER_ID, ProviderStatus.Inactive))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_OWNABLE_UNAUTHORIZED_ACCOUNT);
            });

            it("Is reverted if the provider with the provided id is not active", async () => {
                const { registry } = await loadFixture(deployRegistry);

                await expect(registry.updateProviderStatus(DEFAULT_PROVIDER_ID, ProviderStatus.Inactive))
                    .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_PROVIDER_ID);
            });
        });

        describe("Function 'configureMaxProviderCount()'", async () => {
           it("Executes as expected and emits correct event", async () => {
               const { registry } = await loadFixture(deployRegistry);

               await expect(registry.configureMaxProviderCount(STARTING_MAX_PROVIDER_COUNT + 1))
                   .to.emit(registry, EVENT_NAME_MAX_PROVIDER_COUNT_CONFIGURED)
                   .withArgs(STARTING_MAX_PROVIDER_COUNT + 1);
           });

           it("Is reverted if the caller is not the owner", async () => {
               const { registry } = await loadFixture(deployRegistry);
               const registryConnectedToAttacker = await registry.connect(attacker) as Contract;

               await expect(registryConnectedToAttacker.configureMaxProviderCount(STARTING_MAX_PROVIDER_COUNT + 1))
                   .to.be.revertedWithCustomError(registry, REVERT_ERROR_OWNABLE_UNAUTHORIZED_ACCOUNT);
           });

           it("Is reverted if the new amount is invalid", async () => {
               const { registry } = await loadFixture(deployRegistryAndRegisterProvider);

               await expect(registry.configureMaxProviderCount(0))
                   .to.be.revertedWithCustomError(registry, REVERT_ERROR_INVALID_MAX_PROVIDER_COUNT);
           });
        });
    });
});