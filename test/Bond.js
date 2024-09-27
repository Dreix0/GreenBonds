const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Bond Contract", function () {
    let Bond, bond, owner, addr1, addr2, addr3, paymentToken;

    beforeEach(async function () {
        // Déployez un contrat ERC20 pour simuler la monnaie de paiement
        try {
            const PaymentToken = await ethers.getContractFactory("SimpleERC20");
            paymentToken = await PaymentToken.deploy(ethers.parseUnits("1000000", 18));
            await paymentToken.waitForDeployment();
        } catch (error) {
            console.error("Error deploying PaymentToken:", error);
            throw new Error("PaymentToken deployment failed");
        }

        [owner, addr1, addr2, addr3] = await ethers.getSigners();

        try {
            Bond = await ethers.getContractFactory("Bond");
            bond = await Bond.deploy(
                "BondToken", 
                "BND", 
                500, // interestRateInBips
                100, // faceValue
                paymentToken.target,
                1000, // maxSupply
                Math.floor(Date.now() / 1000) + 86400, // issueDate (1 jour à partir de maintenant)
                10, // issuePrice
                1, // interestPeriodInMonth (en mois, simplifié pour les tests)
                Math.floor(Date.now() / 1000) + 2592000, // firstCouponDate (1 mois à partir de maintenant)
                10 // nbrOfCoupon
            );
            await bond.waitForDeployment();
        } catch (error) {
            console.error("Error deploying Bond:", error);
            throw new Error("Bond deployment failed");
        }

        try {
            // Approvisionner les comptes pour les tests
            await paymentToken.transfer(owner.address, ethers.parseUnits("1000", 18));
            await paymentToken.transfer(addr1.address, ethers.parseUnits("1000", 18));
            await paymentToken.transfer(addr2.address, ethers.parseUnits("1000", 18));
            await paymentToken.connect(owner).approve(bond.target, ethers.parseUnits("1000", 18));
            await paymentToken.connect(addr1).approve(bond.target, ethers.parseUnits("1000", 18));
            await paymentToken.connect(addr2).approve(bond.target, ethers.parseUnits("1000", 18));
            // console.log(await paymentToken.allowance(addr1.address, bond.target));
        } catch (error) {
            console.error("Error transfers:", error);
            throw new Error("Transfers failed");
        }
    });

    describe("Deployment", function () {
        it("Should deploy the contract and set the correct values", async function () {
            expect(await bond.faceValue()).to.equal(100);
            expect(await bond.issuePrice()).to.equal(10);
            expect(await bond.interestRateInBips()).to.equal(500);
            expect(await bond.maxSupply()).to.equal(1000);
        });
    });

    describe("Pre-Purchase Bonds", function () {
        it("Should allow users to pre-purchase bonds", async function () {
            await bond.prePurchaseBond(10);
            expect(await bond.preMintBalances(owner.address)).to.equal(10);
        });

        it("Should fail if the purchase amount exceeds max supply", async function () {
            await bond.prePurchaseBond(1000);
            await expect(bond.prePurchaseBond(1)).to.be.revertedWith("Not enough remaining bonds (max supply reached)");
        });

        it("Should revert if called outside pre-minting phase", async function () {
            await ethers.provider.send("evm_increaseTime", [86400]); // Avance de 1 jour
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            await expect(bond.prePurchaseBond(10)).to.be.revertedWith("Purchase period ended");
        });
    });

    describe("Issue Bonds", function () {
        it("Should allow the owner to issue bonds", async function () {
            await bond.prePurchaseBond(10);
            await ethers.provider.send("evm_increaseTime", [86400]); // Avance de 1 jour
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            expect(await bond.balanceOf(owner.address)).to.equal(10);
        });

        it("Should fail if issue date has not passed", async function () {
            await bond.prePurchaseBond(10);
            await expect(bond.issueBonds()).to.be.revertedWith("The issuance date has not yet passed");
        });

        it("Should revert if called outside pre-minting phase", async function () {
            await ethers.provider.send("evm_increaseTime", [86400]); // Avance de 1 jour
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            await expect(bond.issueBonds()).to.be.revertedWith("Purchase period ended");
        });
    });

    describe("Pay Interest", function () {
        it("Should calculate and pay interest correctly", async function () {
            await bond.prePurchaseBond(10);
            await ethers.provider.send("evm_increaseTime", [2592000]); // Avance de 1 mois
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            await bond.payInterest();
            expect(await bond.interestToClaim(owner.address)).to.be.gt(0);
        });

        it("Should revert if called during pre-mint phase", async function () {
            await expect(bond.payInterest()).to.be.revertedWith("Purchase period not yet ended");
        });
    });

    describe("Claim Interest", function () {
        it("Should allow users to claim their interest", async function () {
            await bond.prePurchaseBond(10);
            await ethers.provider.send("evm_increaseTime", [2592000]); // Avance de 1 mois
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            await bond.payInterest();
            await bond.claimInterest();
            expect(await paymentToken.balanceOf(owner.address)).to.be.lt(ethers.parseUnits("1000", 18));
        });

        it("Should fail if there is no interest to claim", async function () {
            await bond.issueBonds();
            await expect(bond.claimInterest()).to.be.revertedWith("No interest to claim");
        });

        it("Should revert if called before issuance", async function () {
            await bond.prePurchaseBond(10);
            await ethers.provider.send("evm_increaseTime", [2592000]); // Avance de 1 mois
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await expect(bond.claimInterest()).to.be.revertedWith("Purchase period not yet ended");
        });
    });

    describe("Redeem Bonds", function () {
        it("Should allow users to redeem bonds", async function () {
            await bond.prePurchaseBond(10);
            await ethers.provider.send("evm_increaseTime", [2592000]); // Avance de 1 mois
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            await bond.payInterest();
            await bond.redeemBond();
            expect(await bond.balanceOf(owner.address)).to.equal(0);
        });

        it("Should fail if not all coupons have been paid", async function () {
            await bond.prePurchaseBond(10);
            await ethers.provider.send("evm_increaseTime", [2592000]); // Avance de 1 mois
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            await expect(bond.redeemBond()).to.be.revertedWith("Bonds can only be redeemed after maturity and all coupons have been paid");
        }); 

        it("Should fail if the user has no bonds to redeem", async function () {
            await ethers.provider.send("evm_increaseTime", [2592000]); // Avance de 1 mois
            await ethers.provider.send("evm_mine"); // Mine un nouveau bloc
            await bond.issueBonds();
            await bond.payInterest();
            await expect(bond.redeemBond()).to.be.revertedWith("No bonds to redeem");
        });
    });
});
