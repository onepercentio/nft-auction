const { expect, assert } = require("chai");
const { ethers } = require("hardhat");

const { BigNumber } = require("ethers");
// Enable and inject BN dependency

const getAuctionId = require('../helpers/getAuctionId')

const tokenId = 1;
const nftAmount = 1;
const minPrice = 100;
const newMinPrice = 50;
const buyNowPrice = 10000;
const auctionBidPeriod = 86400; //seconds
const bidIncreasePercentage = 10;
const zeroAddress = "0x0000000000000000000000000000000000000000";
const emptyBytes = '0x00';
const zeroERC20Tokens = 0;
const emptyFeeRecipients = [];
const emptyFeePercentages = [];

// Deploy and create a mock erc1155 contract.

describe.skip("Early bid tests", function () {
  let ERC1155;
  let erc1155;
  let NFTAuction;
  let nftAuction;
  let contractOwner;
  let auctionId;
  let user1;
  let user2;
  let user3;

  beforeEach(async function () {
    ERC1155 = await ethers.getContractFactory("ERC1155MockContract");
    NFTAuction = await ethers.getContractFactory("SemiFungibleNFTAuction");
    [ContractOwner, user1, user2, user3] = await ethers.getSigners();

    erc1155 = await ERC1155.deploy("my mockables", "MBA");
    await erc1155.deployed();
    await erc1155.mint(user1.address, tokenId, 1, emptyBytes);

    nftAuction = await NFTAuction.deploy();
    await nftAuction.deployed();
    //approve our smart contract to transfer this NFT
    await erc1155.connect(user1).setApprovalForAll(nftAuction.address, true);
  });
  // whitelisted buyer should be able to purchase NFT
  it("should allow early bids on NFTs", async function () {
    const tx = await nftAuction
      .connect(user2)
      .makeBid(erc1155.address, tokenId, 0, zeroAddress, zeroERC20Tokens, {
        value: minPrice,
      });
    const auctionId = getAuctionId(tx)
    let result = await nftAuction.nftContractAuctions(erc1155.address, tokenId, 0);
    expect(result.nftHighestBidder).to.equal(user2.address);
    expect(result.nftHighestBid.toString()).to.be.equal(
      BigNumber.from(minPrice).toString()
    );
  });
  it("should allow NFT owner to create auction", async function () {
    const tx = await nftAuction
      .connect(user1)
      .createDefaultNftAuction(
        erc1155.address,
        tokenId,
        zeroAddress,
        minPrice,
        buyNowPrice,
        emptyFeeRecipients,
        emptyFeePercentages
      )
    const auctionId = await getAuctionId(tx)

    let result = await nftAuction.nftContractAuctions(erc1155.address, tokenId, auctionId);
    expect(result.minPrice).to.equal(BigNumber.from(minPrice).toString());
  });
  it.skip("should start auction period if early bid is higher than minimum", async function () {
    const tx = await nftAuction
      .connect(user1)
      .createDefaultNftAuction(
        erc1155.address,
        tokenId,
        zeroAddress,
        minPrice,
        buyNowPrice,
        emptyFeeRecipients,
        emptyFeePercentages
      );

    const auctionId = await getAuctionId(tx)

    let result = await nftAuction.nftContractAuctions(erc1155.address, tokenId, auctionId);
    expect(result.auctionEnd).to.be.not.equal(BigNumber.from(0).toString());
  });
  it.skip("should not start auction period if early bid less than minimum", async function () {
    const tx = await nftAuction
      .connect(user1)
      .createDefaultNftAuction(
        erc1155.address,
        tokenId,
        zeroAddress,
        minPrice + 100,
        buyNowPrice,
        emptyFeeRecipients,
        emptyFeePercentages
      );

    let result = await nftAuction.nftContractAuctions(erc1155.address, tokenId, auctionId);
    expect(result.auctionEnd).to.be.equal(BigNumber.from(0).toString());
  });
  it("should not allow minPrice to be updated by other users", async function () {
    const tx = await nftAuction
      .connect(user2)
      .makeBid(erc1155.address, tokenId, 0, zeroAddress, zeroERC20Tokens, {
        value: minPrice,
      });
    const auctionId = getAuctionId(tx)
    await expect(
      nftAuction
        .connect(user2)
        .updateMinimumPrice(erc1155.address, tokenId, auctionId, newMinPrice)
    ).to.be.revertedWith("Only nft seller");
  });
  it("should revert early bid if whitelist sale created for different user", async function () {
    const tx = await nftAuction.connect(user1).createSale(
      erc1155.address,
      tokenId,
      nftAmount,
      zeroAddress,
      buyNowPrice,
      user3.address, //whitelisted buyer
      emptyFeeRecipients,
      emptyFeePercentages
    );
    let result = await nftAuction.nftContractAuctions(erc1155.address, tokenId, auctionId);
    expect(result.auctionEnd).to.be.equal(BigNumber.from(0).toString());
    expect(result.nftHighestBidder).to.be.equal(zeroAddress);
  });
});
