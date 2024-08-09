import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract, ContractFactory } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

interface LatestRoundData {
    roundId: number;
    answer: number;
    startedAt: number;
    updatedAt: number;
    answeredInRound: number;
}

describe("Contract AggregatorMock", async () => {
    const DECIMALS = 8;

    let aggregatorFactory: ContractFactory;
    let deployer: HardhatEthersSigner;

    before(async () => {
        [deployer] = await ethers.getSigners();
        aggregatorFactory = await ethers.getContractFactory("AggregatorMock");
    });

    async function deployAggregator(): Promise<{ aggregator: Contract }> {
        let aggregator: Contract = (await aggregatorFactory.deploy()) as Contract;
        await aggregator.waitForDeployment;
        aggregator = aggregator.connect(deployer) as Contract;

        return {
            aggregator: aggregator
        };
    }

    describe("Function 'decimals()''", async () => {
        it("Returns expected values", async () => {
            const { aggregator } = await loadFixture(deployAggregator);

            expect(await aggregator.decimals()).to.eq(DECIMALS);
        });
    });

    describe("Function 'latestRoundData()'", async () => {
        it("Returns expected values", async () => {
            const { aggregator } = await loadFixture(deployAggregator);

            const expectedRoundData: LatestRoundData = {
                roundId: 0,
                answer: 100000000,
                startedAt: 0,
                updatedAt: 0,
                answeredInRound: 0
            }

            const actualData: LatestRoundData = await aggregator.latestRoundData();
            expect(actualData.answer).to.eq(expectedRoundData.answer);
        });
    });
});