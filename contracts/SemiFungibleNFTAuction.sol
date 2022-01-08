//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";


/// @title An Auction Contract for bidding and selling ERC1155 tokens
// @todo inspired by Avo Lags GmbH
/// @author onepercent.io
/// @notice This contract can be used for auctioning any ERC1155 tokens accepting any ERC20 tokens as payment
contract SemiFungibleNFTAuction is ERC1155Holder {

    using Counters for Counters.Counter;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /*
     * Default values that are used if not specified by the NFT seller.
     */
    uint32 public constant ONE_HOUR = 3600; //1 hour
    uint32 public constant defaultBidIncreasePercentage = 100;
    uint32 public constant bidPercentageConversionFactor = 10000;
    uint32 public constant maximumMinPricePercentage = 8000;
    uint256 public constant defaultTokenAmount = 1;

    // @todo make it upgradeable
    uint32 public defaultBidExtendPeriod = ONE_HOUR;

    Counters.Counter public _ids;

    mapping(uint256 => Auction) public auctions;
    mapping(bytes32 => EnumerableSet.UintSet) private activeAuctionsByToken;
    mapping(address => EnumerableSet.UintSet) private activeAuctionIdsByHolder;
    mapping(address => EnumerableSet.Bytes32Set) private activeAuctionHashesByHolder;

    enum AUCTION_STATUS {
        ACTIVE,
        SETTLED,
        WITHDRAWN
    }

    struct Auction {
        uint256 amount; // amount of tokens being auctioned
        uint256 tokenId;
        uint128 bidIncreasePercentage;
        uint256 minPrice;
        uint256 minNextBid;
        uint256 start;
        uint256 end;
        uint256 highestBid;
        address nftContractAddress;
        address highestBidder;
        address nftSeller;
        address ERC20Token; // The seller can specify an ERC20 token that can be used to bid or purchase the NFT.
        address[] feeRecipients;
        uint32[] feePercentages;
        AUCTION_STATUS status;
    }

    struct NewAuctionRequest {
        address nftContractAddress;
        uint256 tokenId;
        uint256 amount;
        address erc20Token;
        uint256 minPrice;
        uint256 start;
        uint256 end;
        uint32 bidIncreasePercentage;
        address[] feeRecipients;
        uint32[] feePercentages;
    }

    event NftAuctionCreated(Auction auction);

    event BidMade(
        address nftContractAddress,
        uint256 tokenId,
        uint256 auctionId,
        address bidder,
        address erc20Token,
        uint256 tokenAmount
    );

    event AuctionEndUpdated(
        uint256 auctionId,
        uint256 auctionEnd
    );

    event NFTTransferredAndSellerPaid(
        address nftContractAddress,
        uint256 tokenId,
        uint256 amount,
        address nftSeller,
        uint256 highestBid,
        address highestBidder
    );

    event AuctionSettled(
        address nftContractAddress,
        uint256 tokenId,
        address auctionSettler
    );

    event AuctionWithdrawn(
        address nftContractAddress,
        uint256 tokenId,
        address nftOwner
    );

    event BidWithdrawn(
        address nftContractAddress,
        uint256 tokenId,
        address highestBidder
    );

    event MinimumPriceUpdated(
        uint256 auctionId,
        uint256 newMinPrice
    );

    event BuyNowPriceUpdated(
        address nftContractAddress,
        uint256 tokenId,
        uint256 newBuyNowPrice
    );

    event HighestBidTaken(uint256 auctionId, address bidder, uint256 bid);

    modifier auctionOngoing(uint256 _auctionId) {
        require(
            _isAuctionOngoing(_auctionId),
            "Auction has ended"
        );
        _;
    }

    modifier onlyActiveAuction(uint256 _auctionId) {
        require(auctions[_auctionId].status == AUCTION_STATUS.ACTIVE, "Auction has been settled");
        _;
    }

    modifier priceGreaterThanZero(uint256 _price) {
        require(_price > 0, "Price cannot be 0");
        _;
    }

    modifier onlyNftSeller(uint256 _auctionId) {
        require(
            msg.sender == auctions[_auctionId].nftSeller,
            "Only nft seller"
        );
        _;
    }

    modifier minimumBidNotMade(uint _auctionId) {
        require(
            !_isMinimumBidMade(_auctionId),
            "The auction has a valid bid made"
        );
        _;
    }

    modifier isAuctionOver(uint256 _auctionId) {
        require(
            !_isAuctionOngoing(_auctionId),
            "Auction is not yet over"
        );
        _;
    }

    modifier isFeePercentagesLessThanMaximum(uint32[] memory _feePercentages) {
        uint32 totalPercent;
        for (uint256 i = 0; i < _feePercentages.length; i++) {
            totalPercent = totalPercent + _feePercentages[i];
        }
        require(totalPercent <= 10000, "Fee percentages exceed maximum");
        _;
    }

    /*************************************************
     * PUBLIC WRITE METHODS                          *
     *************************************************/

    function createNewNftAuction(NewAuctionRequest calldata _newAuction)
        external
    {
        _validateNewAuction(_newAuction);

        _ids.increment();

        uint256 auctionId = _ids.current();

        uint32 increasePercentage = _newAuction.bidIncreasePercentage == 0
            ? defaultBidIncreasePercentage
            :_newAuction.bidIncreasePercentage;

        Auction memory auction = Auction({
            amount: _newAuction.amount,
            nftContractAddress: _newAuction.nftContractAddress,
            tokenId: _newAuction.tokenId,
            bidIncreasePercentage: increasePercentage,
            minPrice: _newAuction.minPrice,
            minNextBid: _newAuction.minPrice,
            start: _newAuction.start,
            end: _newAuction.end,
            highestBid: 0,
            highestBidder: address(0),
            nftSeller: msg.sender,
            ERC20Token: _newAuction.erc20Token,
            feeRecipients: _newAuction.feeRecipients,
            feePercentages: _newAuction.feePercentages,
            status: AUCTION_STATUS.ACTIVE
        });

        auctions[auctionId] = auction;

        _addActiveAuction(auctionId, auction);

        _lockNFT(auction);

        emit NftAuctionCreated(auction);
    }

    /// @dev  Make bids with ERC20 Token specified by the NFT seller.
    function bid(
        uint256 _auctionId,
        address _erc20Token,
        uint256 _tokenAmount
    )
        external
        auctionOngoing(_auctionId)
        // @todo non-reentrant
    {
        Auction storage auction = auctions[_auctionId];

        require(msg.sender != auction.nftSeller, "Owner cannot bid on own NFT");
        require(block.timestamp <= auction.end, "Auction has ended");
        require(_erc20Token == auction.ERC20Token, "Bid token not accepted");
        require(_tokenAmount >= auction.minNextBid, "Bid amount too low");

        _lockERC20Tokens(_erc20Token, _tokenAmount);

        if (auction.highestBidder != address(0)) {
            // return tokens to previous bidder if there is one
            IERC20(auction.ERC20Token).transfer(auction.highestBidder, auction.highestBid);
        }

        // update highest bid
        auction.highestBid = _tokenAmount;
        auction.highestBidder = msg.sender;
        auction.minNextBid = _tokenAmount * (bidPercentageConversionFactor + auction.bidIncreasePercentage) / bidPercentageConversionFactor;

        _maybeExtendAuctionEnd(_auctionId);

        emit BidMade(
            auction.nftContractAddress,
            auction.tokenId,
            _auctionId,
            msg.sender,
            _erc20Token,
            _tokenAmount
        );
    }

    function settleAuction(uint256 _auctionId)
        external
        isAuctionOver(_auctionId)
        onlyActiveAuction(_auctionId)
    {
        Auction memory auction = auctions[_auctionId];

        auctions[_auctionId].status = AUCTION_STATUS.SETTLED;

        if (auction.highestBid < auction.minPrice) {
            _unlockTokens(auction);
        } else {
            _transferNftAndPaySeller(_auctionId);
        }

        emit AuctionSettled(auction.nftContractAddress, auction.tokenId, msg.sender);

        _removeActiveAuction(_auctionId, auction);
    }

    function withdrawAuction(uint256 _auctionId)
        external
        onlyNftSeller(_auctionId)
        onlyActiveAuction(_auctionId)
        minimumBidNotMade(_auctionId)
    {
        Auction memory auction = auctions[_auctionId];

        auctions[_auctionId].status = AUCTION_STATUS.WITHDRAWN;

        _unlockTokens(auction);

        emit AuctionWithdrawn(auction.nftContractAddress, auction.tokenId, msg.sender);

        _removeActiveAuction(_auctionId, auction);
    }

    function updateMinimumPrice(
        uint256 _auctionId,
        uint256 _newMinPrice
    )
        external
        onlyNftSeller(_auctionId)
        minimumBidNotMade(_auctionId)
        priceGreaterThanZero(_newMinPrice)
    {
        Auction memory auction = auctions[_auctionId];

        auction.minPrice = _newMinPrice;

        emit MinimumPriceUpdated(_auctionId, _newMinPrice);

        _maybeExtendAuctionEnd(_auctionId);
    }

    /*
     * The NFT seller can opt to end an auction by taking the current highest bid.
     */
    function takeHighestBid(uint256 _auctionId)
        external
        onlyNftSeller(_auctionId)
    {
        require(
            _isABidMade(_auctionId),
            "Cannot payout 0 bid"
        );

        Auction memory auction = auctions[_auctionId];

        auctions[_auctionId].status = AUCTION_STATUS.SETTLED;

        _transferNftAndPaySeller(_auctionId);
    
        emit HighestBidTaken(_auctionId, auction.highestBidder, auction.highestBid);

        _removeActiveAuction(_auctionId, auction);
    }

    /*************************************************
     * PUBLIC READ METHODS                           *
     *************************************************/

    function getActiveAuctionHashesByHolder(address _holder)
        external
        view
        returns (Auction[] memory activeAuctions)
    {
        uint256[] memory auctionIdList = activeAuctionIdsByHolder[_holder].values();
        Auction[] memory list = new Auction[](auctionIdList.length);

        for (uint256 i = 0; i < list.length; i++) {
            list[i] = auctions[auctionIdList[i]];
        }

        return list;
    }

    function getActiveAuctionsByToken(address _nftContractAddress, uint256 _tokenId)
        external
        view
        returns (Auction[] memory)
    {
        bytes32 tokenHash = _hashToken(_nftContractAddress, _tokenId);
        uint256[] memory auctionIdList = activeAuctionsByToken[tokenHash].values();
        Auction[] memory list = new Auction[](auctionIdList.length);

        for (uint256 i = 0; i < list.length; i++) {
            list[i] = auctions[auctionIdList[i]];
        }

        return list;
    }

    /*************************************************
     * INTERNAL WRITE METHODS                        *
     *************************************************/

    function _addActiveAuction(uint256 _auctionId, Auction memory _auction)
        internal
    {
        bytes32 tokenHash = _hashToken(_auction.nftContractAddress, _auction.tokenId);

        activeAuctionsByToken[tokenHash].add(_auctionId);
        activeAuctionIdsByHolder[_auction.nftSeller].add(_auctionId);
        activeAuctionHashesByHolder[_auction.nftSeller].add(tokenHash);
    }

    function _removeActiveAuction(uint256 _auctionId, Auction memory _auction)
        internal
    {
        bytes32 tokenHash = _hashToken(_auction.nftContractAddress, _auction.tokenId);

        activeAuctionsByToken[tokenHash].remove(_auctionId);
        activeAuctionIdsByHolder[_auction.nftSeller].remove(_auctionId);
        activeAuctionHashesByHolder[_auction.nftSeller].remove(tokenHash);
    }

    function _lockNFT(Auction memory _auction) internal {
        IERC1155 nftContract = IERC1155(_auction.nftContractAddress);

        uint256 balanceBeforeTransfer = nftContract.balanceOf(address(this), _auction.tokenId);

        nftContract.safeTransferFrom(
            _auction.nftSeller,
            address(this),
            _auction.tokenId,
            _auction.amount,
            new bytes(0)
        );

        uint256 balanceAfterTransfer = nftContract.balanceOf(address(this), _auction.tokenId);

        require(balanceAfterTransfer == balanceBeforeTransfer + _auction.amount, "NFT transfer failed");
    }

    function _lockERC20Tokens(address _erc20Token, uint256 _tokenAmount) internal {
        IERC20 erc20Contract = IERC20(_erc20Token);

        uint256 balanceBeforeTransfer = erc20Contract.balanceOf(address(this));

        IERC20(_erc20Token).transferFrom(
            msg.sender,
            address(this),
            _tokenAmount
        );

        uint256 balanceAfterTransfer = erc20Contract.balanceOf(address(this));

        require(balanceAfterTransfer == balanceBeforeTransfer + _tokenAmount, "ERC20 transfer failed");
    }

     /// @dev transfer back tokens to their original owners
    function _unlockTokens(Auction memory _auction) internal {
        IERC1155(_auction.nftContractAddress).safeTransferFrom(
            address(this),
            _auction.nftSeller,
            _auction.tokenId,
            _auction.amount,
            new bytes(0)
        );

        if (_auction.highestBidder != address(0)) {
            IERC20(_auction.ERC20Token).transfer(
                _auction.highestBidder,
                _auction.highestBid
            );
        }
    }

    function _transferNftAndPaySeller(uint256 _auctionId) internal {
        Auction memory auction = auctions[_auctionId];

        _payFeesAndSeller(auction);

        IERC1155(auction.nftContractAddress).safeTransferFrom(
            address(this),
            auction.highestBidder,
            auction.tokenId,
            auction.amount,
            new bytes(0)
        );

        emit NFTTransferredAndSellerPaid(
            auction.nftContractAddress,
            auction.tokenId,
            auction.amount,
            auction.nftSeller,
            auction.highestBid,
            auction.highestBidder
        );
    }

    function _payFeesAndSeller(Auction memory _auction) internal {
        uint256 feesPaid;
        // pay fees
        for (uint256 i = 0; i < _auction.feeRecipients.length; i++) {
            uint256 fee = _calculateFee(_auction.highestBid, _auction.feePercentages[i]);
            IERC20(_auction.ERC20Token).transfer(_auction.feeRecipients[i], fee);
            feesPaid += fee;
        }
        // pay seller
        IERC20(_auction.ERC20Token).transfer(_auction.nftSeller, (_auction.highestBid - feesPaid));
    }

    function _maybeExtendAuctionEnd(uint256 _auctionId) internal {
        Auction memory auction = auctions[_auctionId];
        if (block.timestamp > auction.end - defaultBidExtendPeriod) {
            auction.end += defaultBidExtendPeriod;

            emit AuctionEndUpdated(_auctionId, auction.end);
        }
    }

    /*************************************************
     * INTERNAL READ METHODS                         *
     *************************************************/

    function _isAuctionOngoing(uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        return (block.timestamp >= auctions[_auctionId].start && block.timestamp <= auctions[_auctionId].end);
    }

    /*
     * Check if a bid has been made.
     */
    function _isABidMade(uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        return auctions[_auctionId].highestBid > 0;
    }

    /*
     *if the minPrice is set by the seller, check that the highest bid meets or exceeds that price.
     */
    function _isMinimumBidMade(uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        Auction memory auction = auctions[_auctionId];
        return auction.minPrice > 0 && (auction.highestBid >= auction.minPrice);
    }

    function _validateNewAuction(NewAuctionRequest memory _newAuction)
        internal
        view
        isFeePercentagesLessThanMaximum(_newAuction.feePercentages)
    {
        require(_newAuction.amount > 0, "Amount cannot be zero");
        require(_newAuction.minPrice > 0, "Price cannot be zero");
        require(_newAuction.bidIncreasePercentage > 0, "Bid increase percentage cannot be zero");
        require(_newAuction.start >= block.timestamp, "Invalid start time");
        require(_newAuction.end >= _newAuction.start, "Invalid end time");
        require(_newAuction.erc20Token != address(0), "Invalid token address");
        require(_newAuction.feeRecipients.length == _newAuction.feePercentages.length, "Recipients != percentages");
        require(
            !activeAuctionHashesByHolder[msg.sender].contains(_hashToken(_newAuction.nftContractAddress, _newAuction.tokenId)),
            "Sender has an active auction for this token"
        );
    }

    function _hashToken(address _nftContractAddress, uint256 _tokenId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_nftContractAddress, _tokenId));
    }

    /*
     * Returns the percentage of the total bid (used to calculate fee payments)
     */
    function _calculateFee(uint256 _totalBid, uint256 _percentage)
        internal
        pure
        returns (uint256)
    {
        return (_totalBid * (_percentage)) / 10000;
    }

}