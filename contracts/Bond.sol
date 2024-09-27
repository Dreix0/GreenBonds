// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Bond is ERC20 {
// Day Count Convention : 30/360

//Utilisation d'oracle pour distribuer les intérêts (owner qui paye) ou réclamer les intérêts (utilisateur qui paye)
// uint32 pour les timestamp (2106 ?)
// Utiliser delete

    uint32 public faceValue; // Face value of bond (in eur, usd or other fiat)
    uint32 public maxSupply; // Maximum number of bonds that can be issued
    uint32 public issueDate; // Issue date (timestamp) after which bonds are issued and can no longer be purchased
    bool public issueStatus; // Boolean indicator indicating whether the bond has already been issued
    uint32 public issuePrice; // Initial purchase price per bond during the presale period (in eur, usd or other fiat)
    uint32 public nbrOfCoupon; // Total number of coupon (interest) payments over the life of the bond
    uint32 public interestRateInBips; // Annual interest rate in bips (1 bip = 0.01%)
    uint32 public interestPeriodInMonth; // Duration of each period between interest payments (in months)
    uint32[] public paymentDates; // Table of coupon payment dates (each date is a timestamp)
    uint256 public lastPayment; // Index of paymentDates[] corresponding to last payment made
    address public owner; // Address of contract owner/issuer
    IERC20 public paymentToken; // Address of the ERC20 token used for payments (eur, usd or other fiat stablecoin)

    // ---   Metadata (IPFS ?)   ---
    //ISINCode
    //Issuer ??
    //Name ??
    //ShortName ??

    // Mapping and table containing the addresses of all those who purchased bonds during the presale period.
    mapping(address => uint32) public preMintBalances;
    address[] public buyers;

    // Mapping and table showing whether an address is or was a bondholder.
    mapping(address => bool) public isHolder;
    address[] public holders;

    // Mapping showing how much interest a bondholder can claim (accumulated interest not yet claimed).
    mapping(address => uint256) public interestToClaim;  //Structure avec isHolder ?

    event BondsPurchased(address indexed investor, uint amount);
    event BondsIssued();
    event InterestPaid(address indexed investor, uint interest);
    event BondsRedeemed(address indexed investor, uint amount);

    constructor(
        string memory name,
        string memory symbol,
        uint32 _interestRateInBips,
        uint32 _faceValue,
        address _paymentToken,
        uint32 _maxSupply,
        uint32 _issueDate,
        uint32 _issuePrice,
        uint32 _interestPeriodInMonth,
        uint32 _firstCouponDate,
        uint32 _nbrOfCoupon
    ) ERC20(name, symbol) {
        faceValue = _faceValue;
        maxSupply = _maxSupply;
        issueDate = _issueDate;
        issuePrice = _issuePrice;
        interestRateInBips = _interestRateInBips;
        interestPeriodInMonth = _interestPeriodInMonth;
        nbrOfCoupon = _nbrOfCoupon;
        paymentDates.push(_firstCouponDate);
        for(uint32 i = 1; i < nbrOfCoupon; i++){
            uint32 current = _firstCouponDate + (i * interestPeriodInMonth * 60 * 60 * 24 * 30);
            paymentDates.push(current);
        }
        paymentToken = IERC20(_paymentToken);
        owner = msg.sender;
    }

    // Modifiers
    modifier onlyDuringPreMint() {
        require(issueStatus == false, "Purchase period ended");
        _;
    }

    modifier onlyAfterPreMint() {
        require(issueStatus == true, "Purchase period not yet ended");
        _;
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "Caller is not the owner");
        _;
    }

    // ERC20 functions overridden
    function decimals() public view virtual override returns (uint8) {
        return 0;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value); 

        if(isHolder[to] == false){
            if(value > 0){
                holders.push(to);
                isHolder[to] = true;
            }
        }
    }

    // Functions

    /* Allows users to purchase bonds during the presale period before issue */
    function prePurchaseBond(uint32 amount) public onlyDuringPreMint{
        require(amount > 0, "Amount must be greater than 0");
        require(totalSupply() + amount <= maxSupply, "Not enough remaining bonds (max supply reached)"); // mettre une variable currentSupply
        require(paymentToken.transferFrom(msg.sender, address(this), (amount * issuePrice)), "Payment failed");

        // If this is the first time this user has purchased bonds, he is added to the list of buyers
        if (preMintBalances[msg.sender] == 0) {
            buyers.push(msg.sender);
        }

        preMintBalances[msg.sender] += amount;

        emit BondsPurchased(msg.sender, amount);
    }

    /* Issues bonds to buyers after the presale period, and transfers collected funds to the owner */
    function issueBonds() public onlyOwner onlyDuringPreMint{
        require(block.timestamp >= issueDate, "The issuance date has not yet passed");

        for(uint256 i = 0; i < buyers.length; i++){
            address investor = buyers[i];
            uint256 amount = preMintBalances[investor];
            if (amount > 0) {
                _mint(investor, amount);
            }
        }

        issueStatus = true; // Changes the status of the issue, preventing any further bond purchases
        
        require(paymentToken.transfer(owner, paymentToken.balanceOf(address(this))), "Payment failed"); // The contract owner receives the funds collected from the sale of the bonds

        emit BondsIssued();
    }

    /* Calculates the coupon amount for each bondholder */
    function payInterest() public onlyAfterPreMint onlyOwner{
        uint256 nbrOfCouponDue = (block.timestamp - paymentDates[lastPayment]) / interestPeriodInMonth;
        if(lastPayment + nbrOfCouponDue > paymentDates.length - 1){
            nbrOfCouponDue = paymentDates.length - 1 - lastPayment;
        }
        uint256 interestDuePerBond = (nbrOfCouponDue * faceValue * interestRateInBips * interestPeriodInMonth) / ( 12 * 10000);
        require(paymentToken.transferFrom(owner, address(this), interestDuePerBond * maxSupply), "Payment failed");
        
        for(uint256 i = 0; i < holders.length; i++){
            uint256 interestDue = balanceOf(holders[i]) * interestDuePerBond;
            interestToClaim[holders[i]] += interestDue;
        }

        lastPayment += nbrOfCouponDue;
    }

    /* Allows bondholders to claim their accumulated interest */
    function claimInterest() public onlyAfterPreMint{
        require(interestToClaim[msg.sender] > 0, "No interest to claim");
        require(paymentToken.transfer(msg.sender, interestToClaim[msg.sender]), "Payment failed");
        emit InterestPaid(msg.sender, interestToClaim[msg.sender]);
        interestToClaim[msg.sender] = 0;
    }

    /* Enables bondholders to receive the face value of their bonds on the maturity date, with remaining interest */
    function redeemBond() public onlyAfterPreMint{
        require(lastPayment == paymentDates.length - 1, "Bonds can only be redeemed after maturity and all coupons have been paid");
        uint256 bondAmount = balanceOf(msg.sender);
        require(bondAmount > 0, "No bonds to redeem");
        uint256 redeemAmount = bondAmount * faceValue;
        _burn(msg.sender, bondAmount);
        require(paymentToken.transfer(msg.sender, redeemAmount), "Payment failed");
        emit BondsRedeemed(msg.sender, bondAmount);
        if(interestToClaim[msg.sender] > 0){
            require(paymentToken.transfer(msg.sender, interestToClaim[msg.sender]), "Payment failed");
            emit InterestPaid(msg.sender, interestToClaim[msg.sender]);
            interestToClaim[msg.sender] = 0;
        }
        // optimiser avec un seul transfer
    }
}