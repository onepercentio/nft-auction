//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";


/// @title An Auction Contract for bidding and selling single and batched NFTs
/// @author Avo Labs GmbH
/// @notice This contract can be used for auctioning any NFTs, and accepts any ERC20 token as payment
contract SemiFungibleNFTAuction is ERC1155Holder {

    using Counters for Counters.Counter;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*
     * Default values that are used if not specified by the NFT seller.
     */
    uint32 public constant ONE_HOUR = 3600; //1 hour
    uint32 public constant defaultBidExtendPeriod = ONE_HOUR;
    uint32 public constant defaultBidIncreasePercentage = 100;
    uint32 public constant minimumSettableIncreasePercentage = 100;
    uint32 public constant maximumMinPricePercentage = 8000;
    uint256 public constant defaultTokenAmount = 1;

    Counters.Counter public _ids;

    mapping(bytes32 => EnumerableSet.AddressSet) private _roleMembers;
    // @dev tokenAddress => tokenId => auctionId => auction
    mapping(address => mapping(uint256 => mapping(uint256 => Auction))) public nftContractAuctions;
    // fractionable NFTs can have multiple active auctions but only one by holder
    // @dev holderAddress => tokenAddress => tokenId => auctionId
    mapping(address => mapping(address => mapping(uint256 => uint256))) public activeAuctionsByHolder;
    mapping(address => uint256) failedTransferCredits;
    struct Auction {
        uint256 id;
        uint256 amount; // amount of tokens being auctioned
        uint32 bidIncreasePercentage;
        uint32 bidExtendPeriod; //Increments the length of time the auction is open in which a new bid can be made after each bid.
        uint256 minPrice;
        uint256 minNextBid;
        uint256 start;
        uint256 end;
        uint256 highestBid;
        address highestBidder;
        address nftSeller;
        address ERC20Token; // The seller can specify an ERC20 token that can be used to bid or purchase the NFT.
        address[] feeRecipients;
        uint32[] feePercentages;
        bool tokensLocked;
    }

    /*╔═════════════════════════════╗
      ║           EVENTS            ║
      ╚═════════════════════════════╝*/

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

    // event WhitelistedBuyerUpdated(
    //     address nftContractAddress,
    //     uint256 tokenId,
    //     address newWhitelistedBuyer
    // );

    event MinimumPriceUpdated(
        address nftContractAddress,
        uint256 tokenId,
        uint256 newMinPrice
    );

    event BuyNowPriceUpdated(
        address nftContractAddress,
        uint256 tokenId,
        uint256 newBuyNowPrice
    );

    event HighestBidTaken(address nftContractAddress, uint256 tokenId);
    /**********************************/
    /*╔═════════════════════════════╗
      ║             END             ║
      ║            EVENTS           ║
      ╚═════════════════════════════╝*/
    /**********************************/
    /*╔═════════════════════════════╗
      ║          MODIFIERS          ║
      ╚═════════════════════════════╝*/

    modifier auctionOngoing(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId) {
        require(
            _isAuctionOngoing(_nftContractAddress, _tokenId, _auctionId),
            "Auction has ended"
        );
        _;
    }

    modifier priceGreaterThanZero(uint256 _price) {
        require(_price > 0, "Price cannot be 0");
        _;
    }

    modifier notNftSeller(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId) {
        require(
            msg.sender !=
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftSeller,
            "Owner cannot bid on own NFT"
        );
        _;
    }

    modifier onlyNftSeller(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId) {
        require(
            msg.sender ==
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftSeller,
            "Only nft seller"
        );
        _;
    }
    // check if the highest bidder can purchase this NFT.
    modifier onlyApplicableBuyer(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) {
        // require(
            // @todo check this
            // !_isWhitelistedSale(_nftContractAddress, _tokenId, _auctionId) ||
            //     nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            //         .whitelistedBuyer ==
            //     msg.sender,
            // "Only the whitelisted buyer"
        // );
        _;
    }

    modifier minimumBidNotMade(address _nftContractAddress, uint256 _tokenId, uint _auctionId) {
        require(
            !_isMinimumBidMade(_nftContractAddress, _tokenId, _auctionId),
            "The auction has a valid bid made"
        );
        _;
    }

    modifier isAuctionOver(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId) {
        require(
            !_isAuctionOngoing(_nftContractAddress, _tokenId, _auctionId),
            "Auction is not yet over"
        );
        _;
    }

    modifier notZeroAddress(address _address) {
        require(_address != address(0), "Cannot specify 0 address");
        _;
    }

    modifier increasePercentageAboveMinimum(uint32 _bidIncreasePercentage) {
        require(
            _bidIncreasePercentage >= minimumSettableIncreasePercentage,
            "Bid increase percentage too low"
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

    modifier correctFeeRecipientsAndPercentages(
        uint256 _recipientsLength,
        uint256 _percentagesLength
    ) {
        require(
            _recipientsLength == _percentagesLength,
            "Recipients != percentages"
        );
        _;
    }

    // modifier isNotASale(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId) {
    //     require(
    //         !_isASale(_nftContractAddress, _tokenId, _auctionId),
    //         "Not applicable for a sale"
    //     );
    //     _;
    // }

    /**********************************/
    /*╔═════════════════════════════╗
      ║             END             ║
      ║          MODIFIERS          ║
      ╚═════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║    AUCTION CHECK FUNCTIONS   ║
      ╚══════════════════════════════╝*/
    function _isAuctionOngoing(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        uint256 auctionEndTimestamp = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].end;
        return (block.timestamp <= auctionEndTimestamp);
    }

    /*
     * Check if a bid has been made. This is applicable in the early bid scenario
     * to ensure that if an auction is created after an early bid, the auction
     * begins appropriately or is settled if the buy now price is met.
     */
    function _isABidMade(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        return (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].highestBid > 0);
    }

    /*
     *if the minPrice is set by the seller, check that the highest bid meets or exceeds that price.
     */
    function _isMinimumBidMade(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        Auction memory auction = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId];
        return auction.minPrice > 0 && (auction.highestBid >= auction.minPrice);
    }

    /*
     * An NFT is up for sale if the buyNowPrice is set, but the minPrice is not set.
     * Therefore the only way to conclude the NFT sale is to meet the buyNowPrice.
     */
    // function _isASale(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
    //     internal
    //     view
    //     returns (bool)
    // {
    //     return (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].buyNowPrice >
    //         0 &&
    //         return nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].minPrice == 0);
    // }

    // @todo update this
    // function _isWhitelistedSale(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
    //     internal
    //     view
    //     returns (bool)
    // {
    //     return (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
    //         .whitelistedBuyer != address(0));
    // }

    /*
     * The highest bidder is allowed to purchase the NFT if
     * no whitelisted buyer is set by the NFT seller.
     * Otherwise, the highest bidder must equal the whitelisted buyer.
     */
    function _isHighestBidderAllowedToPurchaseNFT(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal view returns (bool) {
        // @todo check this
        // return
            // (!_isWhitelistedSale(_nftContractAddress, _tokenId, _auctionId)) ||
            // _isHighestBidderWhitelisted(_nftContractAddress, _tokenId, _auctionId);
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║    AUCTION CHECK FUNCTIONS   ║
      ╚══════════════════════════════╝*/

    /*╔══════════════════════════════╗
      ║       AUCTION CREATION       ║
      ╚══════════════════════════════╝*/
    function _validateNewAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _start,
        uint256 _end,
        uint256 _amount,
        uint256 _minPrice,
        uint32 _bidIncreasePercentage,
        address _erc20Token,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    ) internal view isFeePercentagesLessThanMaximum(_feePercentages) {
        require(_start >= block.timestamp, "Invalid start time");
        require(_end >= _start, "Invalid end time");
        require(_amount > 0, "Amount cannot be 0");
        require(_minPrice > 0, "Price cannot be 0");
        require(_erc20Token != address(0), "Invalid token address");
        require(activeAuctionsByHolder[msg.sender][_nftContractAddress][_tokenId] == 0, "Sender has an active auction for this NFT");
        require(_feeRecipients.length == _feePercentages.length, "Recipients != percentages");
        require(_bidIncreasePercentage >= minimumSettableIncreasePercentage, "Bid increase percentage too low");
    }

    function createNewNftAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _amount,
        address _erc20Token,
        uint256 _minPrice,
        uint256 _start,
        uint256 _end,
        uint32 _bidIncreasePercentage,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    )
        external
    {
        _validateNewAuction(
            _nftContractAddress,
            _tokenId,
            _start,
            _end,
            _amount,
            _minPrice,
            _bidIncreasePercentage,
            _erc20Token,
            _feeRecipients,
            _feePercentages
        );

        _ids.increment();

        uint256 auctionId = _ids.current();

        uint32 increasePercentage = _bidIncreasePercentage == 0
            ? defaultBidIncreasePercentage
            :_bidIncreasePercentage;

        Auction memory auction = Auction({
            id: auctionId,
            amount: _amount,
            bidIncreasePercentage: increasePercentage,
            bidExtendPeriod: ONE_HOUR,
            minPrice: _minPrice,
            minNextBid: _minPrice,
            start: _start,
            end: _end,
            highestBid: 0,
            highestBidder: address(0),
            nftSeller: msg.sender,
            ERC20Token: _erc20Token,
            feeRecipients: _feeRecipients,
            feePercentages: _feePercentages,
            tokensLocked: false
        });

        nftContractAuctions[_nftContractAddress][_tokenId][auctionId] = auction;

        activeAuctionsByHolder[msg.sender][_nftContractAddress][_tokenId] = auctionId;

        _lockNFT(auction, _nftContractAddress, _tokenId);

        emit NftAuctionCreated(auction);
    }

    function _lockNFT(Auction memory _auction, address _nftContractAddress, uint256 _tokenId) internal {
        IERC1155(_nftContractAddress).safeTransferFrom(
            _auction.nftSeller,
            address(this),
            _tokenId,
            _auction.amount,
            new bytes(0)
        );

        _auction.tokensLocked = true;
    }

    /********************************************************************
     * Make bids with ERC20 Token specified by the NFT seller.          *
     ********************************************************************/
    function bid(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _erc20Token,
        uint256 _tokenAmount
    )
        external
        // @todo non-reentrant
    {
        Auction storage auction = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId];

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

        // @todo update minNextBid

        _maybeExtendAuctionEnd(auction);

        emit BidMade(
            _nftContractAddress,
            _tokenId,
            _auctionId,
            msg.sender,
            _erc20Token,
            _tokenAmount
        );
    }

    function _lockERC20Tokens(address _erc20Token, uint256 _tokenAmount) internal {
        IERC20(_erc20Token).transferFrom(
            msg.sender,
            address(this),
            _tokenAmount
        );
    }

    function _maybeExtendAuctionEnd(Auction memory _auction) internal {
        if (block.timestamp > _auction.end - defaultBidExtendPeriod) {
            _auction.end += defaultBidExtendPeriod;

            emit AuctionEndUpdated(
                _auction.id,
                _auction.end
            );
        }
    }

    function _transferNftAndPaySeller(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal {
        Auction memory auction = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId];

        _payFeesAndSeller(auction);

        IERC1155(_nftContractAddress).safeTransferFrom(
            address(this),
            auction.highestBidder,
            _tokenId,
            auction.amount,
            new bytes(0)
        );

        emit NFTTransferredAndSellerPaid(
            _nftContractAddress,
            _tokenId,
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

    function settleAuction(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        external
        isAuctionOver(_nftContractAddress, _tokenId, _auctionId)
    {
        // @todo only auctions with bids above minimum can be settled
        _transferNftAndPaySeller(_nftContractAddress, _tokenId, _auctionId);
        emit AuctionSettled(_nftContractAddress, _tokenId, msg.sender);
    }

    // @todo only auctions with no bids greater than the minimum price can be withdrawn
    // function withdrawAuction(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
    //     external
    // {
    //     //only the NFT owner can prematurely close and auction
    //     require(
    //         IERC1155(_nftContractAddress).balanceOf(msg.sender, _tokenId) > 0,
    //         // IERC1155(_nftContractAddress).ownerOf(_tokenId) == msg.sender,
    //         "Not NFT owner"
    //     );
    //     // _resetAuction(_nftContractAddress, _tokenId, _auctionId);
    //     emit AuctionWithdrawn(_nftContractAddress, _tokenId, msg.sender);
    // }

    /**
     * @dev bids lower than minimum price can be withdrawn
     */
    // function withdrawBid(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
    //     external
    //     minimumBidNotMade(_nftContractAddress, _tokenId, _auctionId)
    // {
    //     Auction memory auction = 
    //     address highestBidder = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].highestBidder;
    //     require(msg.sender == highestBidder, "Cannot withdraw funds");

    //     uint256 highestBid = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].highestBid;
    //     // _resetBids(_nftContractAddress, _tokenId, _auctionId);

    //     IERC20(_auction.ERC20Token).transfer(_auction.nftSeller, (_auction.highestBid - feesPaid));
    //     _payout(_nftContractAddress, _tokenId, _auctionId, highestBidder, highestBid);

    //     emit BidWithdrawn(_nftContractAddress, _tokenId, msg.sender);
    // }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║      SETTLE & WITHDRAW       ║
      ╚══════════════════════════════╝*/
    /**********************************/

    function updateMinimumPrice(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint256 _newMinPrice
    )
        external
        onlyNftSeller(_nftContractAddress, _tokenId, _auctionId)
        minimumBidNotMade(_nftContractAddress, _tokenId, _auctionId)
        priceGreaterThanZero(_newMinPrice)
    {
        Auction memory auction = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId];

        auction.minPrice = _newMinPrice;

        emit MinimumPriceUpdated(_nftContractAddress, _tokenId, _newMinPrice);

        _maybeExtendAuctionEnd(auction);
    }

    /*
     * The NFT seller can opt to end an auction by taking the current highest bid.
     */
    function takeHighestBid(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        external
        onlyNftSeller(_nftContractAddress, _tokenId, _auctionId)
    {
        require(
            _isABidMade(_nftContractAddress, _tokenId, _auctionId),
            "cannot payout 0 bid"
        );
        _transferNftAndPaySeller(_nftContractAddress, _tokenId, _auctionId);
        emit HighestBidTaken(_nftContractAddress, _tokenId);
    }

}
