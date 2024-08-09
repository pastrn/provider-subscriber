import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract, ContractFactory } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("Contract TokenMock", async () => {
  const TOKEN_NAME = "TestToken";
  const TOKEN_SYMBOL = "TEST";
  const PREMINT = "1000000000000000000000000";

  let tokenFactory: ContractFactory;
  let deployer: HardhatEthersSigner;

  before(async () => {
    [deployer] = await ethers.getSigners();
    tokenFactory = await ethers.getContractFactory("TestToken");
  });

  async function deployToken(): Promise<{ token: Contract }> {
    let token: Contract = (await tokenFactory.deploy()) as Contract;
    await token.waitForDeployment;
    token = token.connect(deployer) as Contract;

    return {
      token
    };
  }

  describe("Constructor'", async () => {
    it("Configures contract as expected", async () => {
      const { token } = await loadFixture(deployToken);

      expect(await token.name()).to.eq(TOKEN_NAME);
      expect(await token.symbol()).to.eq(TOKEN_SYMBOL);
      expect(String(await token.balanceOf(deployer.address))).to.eq(PREMINT);
    });
  });
});