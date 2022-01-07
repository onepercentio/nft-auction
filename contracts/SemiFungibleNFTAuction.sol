//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/// @title An Auction Contract for bidding and selling single and batched NFTs
/// @author Avo Labs GmbH
/// @notice This contract can be used for auctioning any NFTs, and accepts any ERC20 token as payment
contract SemiFungibleNFTAuction is ERC1155Holder {

    using Counters for Counters.Counter;
    /*
     * Default values that are used if not specified by the NFT seller.
     */
    uint32 public constant defaultBidIncreasePercentage = 100;
    uint32 public constant defaultAuctionBidPeriod = 86400; //1 day
    uint32 public constant minimumSettableIncreasePercentage = 100;
    uint32 public constant maximumMinPricePercentage = 8000;
    uint256 public constant defaultTokenAmount = 1;

    Counters.Counter public _ids;

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
        uint32 auctionBidPeriod; //Increments the length of time the auction is open in which a new bid can be made after each bid.
        uint64 auctionEnd;
        uint128 minPrice;
        uint128 buyNowPrice;
        uint128 nftHighestBid;
        address nftHighestBidder;
        address nftSeller;
        address whitelistedBuyer; //The seller can specify a whitelisted address for a sale (this is effectively a direct sale).
        address nftRecipient; //The bidder can specify a recipient for the NFT if their bid is successful.
        address ERC20Token; // The seller can specify an ERC20 token that can be used to bid or purchase the NFT.
        address[] feeRecipients;
        uint32[] feePercentages;
        bool tokensLocked;
    }

    /*╔═════════════════════════════╗
      ║           EVENTS            ║
      ╚═════════════════════════════╝*/

    event NftAuctionCreated(
        address nftContractAddress,
        uint256 tokenId,
        uint256 id,
        uint256 amount,
        address nftSeller,
        address erc20Token,
        uint128 minPrice,
        uint128 buyNowPrice,
        uint32 auctionBidPeriod,
        uint32 bidIncreasePercentage,
        address[] feeRecipients,
        uint32[] feePercentages
    );

    event SaleCreated(
        address nftContractAddress,
        uint256 tokenId,
        uint256 id,
        uint256 amount,
        address nftSeller,
        address erc20Token,
        uint128 buyNowPrice,
        address whitelistedBuyer,
        address[] feeRecipients,
        uint32[] feePercentages
    );

    event BidMade(
        address nftContractAddress,
        uint256 tokenId,
        address bidder,
        uint256 ethAmount,
        address erc20Token,
        uint256 tokenAmount
    );

    event AuctionPeriodUpdated(
        address nftContractAddress,
        uint256 tokenId,
        uint64 auctionEndPeriod
    );

    event NFTTransferredAndSellerPaid(
        address nftContractAddress,
        uint256 tokenId,
        uint256 amount,
        address nftSeller,
        uint128 nftHighestBid,
        address nftHighestBidder,
        address nftRecipient
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

    event WhitelistedBuyerUpdated(
        address nftContractAddress,
        uint256 tokenId,
        address newWhitelistedBuyer
    );

    event MinimumPriceUpdated(
        address nftContractAddress,
        uint256 tokenId,
        uint256 newMinPrice
    );

    event BuyNowPriceUpdated(
        address nftContractAddress,
        uint256 tokenId,
        uint128 newBuyNowPrice
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

    modifier isNotAuctioningThisNFT(
        address _nftContractAddress,
        uint256 _tokenId
    ) {
        require(
            activeAuctionsByHolder[msg.sender][_nftContractAddress][_tokenId] == 0,
            "Sender has an active auction for this NFT"
        );
        _;
    }

    // modifier isAuctionNotStartedByOwner(
    //     address _nftContractAddress,
    //     uint256 _tokenId
    // ) {
    //     require(
    //         activeAuctionsByHolder[msg.sender][_nftContractAddress][_tokenId] == 0
    //         // nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftSeller !=
    //         //     msg.sender,
    //         "Auction already started by owner"
    //     );

    //     if (activeAuctionsByHolder[msg.sender][_nftContractAddress][_tokenId] == 0) {
    //         require(
    //             IERC1155(_nftContractAddress).balanceOf(msg.sender, _tokenId) > 0,
    //             "Sender doesn't own NFT"
    //         );

    //         _resetAuction(_nftContractAddress, _tokenId, _auctionId);
    //     }
    //     _;
    // }

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
    /*
     * The minimum price must be 80% of the buyNowPrice(if set).
     */
    modifier minPriceDoesNotExceedLimit(
        uint128 _buyNowPrice,
        uint128 _minPrice
    ) {
        require(
            _buyNowPrice == 0 ||
                _getPortionOfBid(_buyNowPrice, maximumMinPricePercentage) >=
                _minPrice,
            "MinPrice > 80% of buyNowPrice"
        );
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
    /*
     * The bid amount was either equal the buyNowPrice or it must be higher than the previous
     * bid by the specified bid increase percentage.
     */
    modifier bidAmountMeetsBidRequirements(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint128 _tokenAmount
    ) {
        require(
            _doesBidMeetBidRequirements(
                _nftContractAddress,
                _tokenId,
                _auctionId,
                _tokenAmount
            ),
            "Not enough funds to bid on NFT"
        );
        _;
    }
    // check if the highest bidder can purchase this NFT.
    modifier onlyApplicableBuyer(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) {
        require(
            !_isWhitelistedSale(_nftContractAddress, _tokenId, _auctionId) ||
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                    .whitelistedBuyer ==
                msg.sender,
            "Only the whitelisted buyer"
        );
        _;
    }

    modifier minimumBidNotMade(address _nftContractAddress, uint256 _tokenId, uint _auctionId) {
        require(
            !_isMinimumBidMade(_nftContractAddress, _tokenId, _auctionId),
            "The auction has a valid bid made"
        );
        _;
    }

    /*
     * Payment is accepted if the payment is made in the ERC20 token or ETH specified by the seller.
     * Early bids on NFTs not yet up for auction must be made in ETH.
     */
    modifier paymentAccepted(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _erc20Token,
        uint128 _tokenAmount
    ) {
        require(
            _isPaymentAccepted(
                _nftContractAddress,
                _tokenId,
                _auctionId,
                _erc20Token,
                _tokenAmount
            ),
            "Bid to be in specified ERC20/Eth"
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

    modifier isNotASale(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId) {
        require(
            !_isASale(_nftContractAddress, _tokenId, _auctionId),
            "Not applicable for a sale"
        );
        _;
    }

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
        uint64 auctionEndTimestamp = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].auctionEnd;
        //if the auctionEnd is set to 0, the auction is technically on-going, however
        //the minimum bid price (minPrice) has not yet been met.
        return (auctionEndTimestamp == 0 ||
            block.timestamp < auctionEndTimestamp);
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
        return (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftHighestBid > 0);
    }

    /*
     *if the minPrice is set by the seller, check that the highest bid meets or exceeds that price.
     */
    function _isMinimumBidMade(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        uint128 minPrice = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .minPrice;
        return
            minPrice > 0 &&
            (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid >=
                minPrice);
    }

    /*
     * If the buy now price is set by the seller, check that the highest bid meets that price.
     */
    function _isBuyNowPriceMet(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        uint128 buyNowPrice = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .buyNowPrice;
        return
            buyNowPrice > 0 &&
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid >=
            buyNowPrice;
    }

    /*
     * Check that a bid is applicable for the purchase of the NFT.
     * In the case of a sale: the bid needs to meet the buyNowPrice.
     * In the case of an auction: the bid needs to be a % higher than the previous bid.
     */
    function _doesBidMeetBidRequirements(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint128 _tokenAmount
    ) internal view returns (bool) {
        uint128 buyNowPrice = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .buyNowPrice;
        //if buyNowPrice is met, ignore increase percentage
        if (
            buyNowPrice > 0 &&
            (msg.value >= buyNowPrice || _tokenAmount >= buyNowPrice)
        ) {
            return true;
        }
        //if the NFT is up for auction, the bid needs to be a % higher than the previous bid
        uint256 bidIncreaseAmount = (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftHighestBid *
            (10000 +
                _getBidIncreasePercentage(_nftContractAddress, _tokenId, _auctionId))) /
            10000;
        return (msg.value >= bidIncreaseAmount ||
            _tokenAmount >= bidIncreaseAmount);
    }

    /*
     * An NFT is up for sale if the buyNowPrice is set, but the minPrice is not set.
     * Therefore the only way to conclude the NFT sale is to meet the buyNowPrice.
     */
    function _isASale(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        return (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].buyNowPrice >
            0 &&
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].minPrice == 0);
    }

    function _isWhitelistedSale(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (bool)
    {
        return (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .whitelistedBuyer != address(0));
    }

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
        return
            (!_isWhitelistedSale(_nftContractAddress, _tokenId, _auctionId)) ||
            _isHighestBidderWhitelisted(_nftContractAddress, _tokenId, _auctionId);
    }

    function _isHighestBidderWhitelisted(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal view returns (bool) {
        return (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftHighestBidder ==
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                .whitelistedBuyer);
    }

    /**
     * Payment is accepted in the following scenarios:
     * (1) Auction already created - can accept ETH or Specified Token
     *  --------> Cannot bid with ETH & an ERC20 Token together in any circumstance<------
     * (2) Auction not created - only ETH accepted (cannot early bid with an ERC20 Token
     * (3) Cannot make a zero bid (no ETH or Token amount)
     */
    function _isPaymentAccepted(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _bidERC20Token,
        uint128 _tokenAmount
    ) internal view returns (bool) {
        address auctionERC20Token = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].ERC20Token;
        if (_isERC20Auction(auctionERC20Token)) {
            return
                msg.value == 0 &&
                auctionERC20Token == _bidERC20Token &&
                _tokenAmount > 0;
        } else {
            return
                msg.value != 0 &&
                _bidERC20Token == address(0) &&
                _tokenAmount == 0;
        }
    }

    function _isERC20Auction(address _auctionERC20Token)
        internal
        pure
        returns (bool)
    {
        return _auctionERC20Token != address(0);
    }

    /*
     * Returns the percentage of the total bid (used to calculate fee payments)
     */
    function _getPortionOfBid(uint256 _totalBid, uint256 _percentage)
        internal
        pure
        returns (uint256)
    {
        return (_totalBid * (_percentage)) / 10000;
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║    AUCTION CHECK FUNCTIONS   ║
      ╚══════════════════════════════╝*/
    /**********************************/
    /*╔══════════════════════════════╗
      ║    DEFAULT GETTER FUNCTIONS  ║
      ╚══════════════════════════════╝*/
    /*****************************************************************
     * These functions check if the applicable auction parameter has *
     * been set by the NFT seller. If not, return the default value. *
     *****************************************************************/

    function _getBidIncreasePercentage(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal view returns (uint32) {
        uint32 bidIncreasePercentage = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].bidIncreasePercentage;

        if (bidIncreasePercentage == 0) {
            return defaultBidIncreasePercentage;
        } else {
            return bidIncreasePercentage;
        }
    }

    function _getAuctionBidPeriod(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (uint32)
    {
        uint32 auctionBidPeriod = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].auctionBidPeriod;

        if (auctionBidPeriod == 0) {
            return defaultAuctionBidPeriod;
        } else {
            return auctionBidPeriod;
        }
    }

    /*
     * The default value for the NFT recipient is the highest bidder
     */
    function _getNftRecipient(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
        view
        returns (address)
    {
        address nftRecipient = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftRecipient;

        if (nftRecipient == address(0)) {
            return
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBidder;
        } else {
            return nftRecipient;
        }
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║    DEFAULT GETTER FUNCTIONS  ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║  TRANSFER NFTS TO CONTRACT   ║
      ╚══════════════════════════════╝*/
    function _transferNftsToAuctionContract(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal {
        // if tokens have been locked, just return
        if (nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].tokensLocked) return;

        address _nftSeller = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftSeller;
        uint256 _amount = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].amount;
        uint256 _currentBalance = IERC1155(_nftContractAddress).balanceOf(address(this), _tokenId);

        if (IERC1155(_nftContractAddress).balanceOf(_nftSeller, _tokenId) >= _amount) {
            IERC1155(_nftContractAddress).safeTransferFrom(
                _nftSeller,
                address(this),
                _tokenId,
                _amount,
                new bytes(0)
            );
            require(
                IERC1155(_nftContractAddress).balanceOf(address(this), _tokenId) == _amount + _currentBalance,
                "nft transfer failed"
            );
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].tokensLocked = true;
        } else {
            require(
                IERC1155(_nftContractAddress).balanceOf(address(this), _tokenId) >= _amount,
                "Insufficient sender NFT balance"
            );
        }
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║  TRANSFER NFTS TO CONTRACT   ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║       AUCTION CREATION       ║
      ╚══════════════════════════════╝*/

    /**
     * Setup parameters applicable to all auctions and whitelised sales:
     * -> ERC20 Token for payment (if specified by the seller) : _erc20Token
     * -> minimum price : _minPrice
     * -> buy now price : _buyNowPrice
     * -> the nft seller: msg.sender
     * -> The fee recipients & their respective percentages for a sucessful auction/sale
     */
    function _setupAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint256 _amount,
        address _erc20Token,
        uint128 _minPrice,
        uint128 _buyNowPrice,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    )
        internal
        minPriceDoesNotExceedLimit(_buyNowPrice, _minPrice)
        isFeePercentagesLessThanMaximum(_feePercentages)
    {
        // @todo solve 'stack too deep error' and rollback to modifier check
        require(
            _feeRecipients.length == _feePercentages.length,
            "Recipients != percentages"
        );
        Auction storage _auction = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId];
        if (_erc20Token != address(0)) {
           _auction.ERC20Token = _erc20Token;
        }
       _auction.feeRecipients = _feeRecipients;
       _auction.feePercentages = _feePercentages;
       _auction.buyNowPrice = _buyNowPrice;
       _auction.minPrice = _minPrice;
       _auction.nftSeller = msg.sender;
       _auction.amount = _amount;
       _auction.id = _auctionId;
    }

    function _createNewNftAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _amount,
        address _erc20Token,
        uint128 _minPrice,
        uint128 _buyNowPrice,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    ) internal {
        _ids.increment();
        uint256 id = _ids.current();
        // Sending the NFT to this contract
        _setupAuction(
            _nftContractAddress,
            _tokenId,
            id,
            _amount,
            _erc20Token,
            _minPrice,
            _buyNowPrice,
            _feeRecipients,
            _feePercentages
        );
        uint32 _auctionBidPeriod = _getAuctionBidPeriod(_nftContractAddress, _tokenId, id);
        uint32 _increasePercentage = _getBidIncreasePercentage(_nftContractAddress, _tokenId, id);
        emit NftAuctionCreated(
            _nftContractAddress,
            _tokenId,
            id,
            _amount,
            msg.sender,
            _erc20Token,
            _minPrice,
            _buyNowPrice,
            _auctionBidPeriod,
            _increasePercentage,
            _feeRecipients,
            _feePercentages
        );
        _updateOngoingAuction(_nftContractAddress, _tokenId, id);
    }

    /**
     * Create an auction that uses the default bid increase percentage
     * & the default auction bid period.
     */
    function createDefaultNftAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        address _erc20Token,
        uint128 _minPrice,
        uint128 _buyNowPrice,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    )
        external
        isNotAuctioningThisNFT(_nftContractAddress, _tokenId)
        priceGreaterThanZero(_minPrice)
    {
        _createNewNftAuction(
            _nftContractAddress,
            _tokenId,
            defaultTokenAmount,
            _erc20Token,
            _minPrice,
            _buyNowPrice,
            _feeRecipients,
            _feePercentages
        );
    }

    function createNewNftAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _amount,
        address _erc20Token,
        uint128 _minPrice,
        uint128 _buyNowPrice,
        uint32 _auctionBidPeriod, //this is the time that the auction lasts until another bid occurs
        uint32 _bidIncreasePercentage,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    )
        external
        // @todo stack too deep
        isNotAuctioningThisNFT(_nftContractAddress, _tokenId)
        // increasePercentageAboveMinimum(_bidIncreasePercentage)
    {
        require(_minPrice > 0, "Price cannot be 0");
        require(
            _bidIncreasePercentage >= minimumSettableIncreasePercentage,
            "Bid increase percentage too low"
        );
        // nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].auctionBidPeriod = _auctionBidPeriod;
        // nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].bidIncreasePercentage = _bidIncreasePercentage;
        _createNewNftAuction(
            _nftContractAddress,
            _tokenId,
            _amount,
            _erc20Token,
            _minPrice,
            _buyNowPrice,
            _feeRecipients,
            _feePercentages
        );
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║       AUCTION CREATION       ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║            SALES             ║
      ╚══════════════════════════════╝*/

    /********************************************************************
     * Allows for a standard sale mechanism where the NFT seller can    *
     * can select an address to be whitelisted. This address is then    *
     * allowed to make a bid on the NFT. No other address can bid on    *
     * the NFT.                                                         *
     ********************************************************************/
    function _setupSale(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint256 _amount,
        address _erc20Token,
        uint128 _buyNowPrice,
        address _whitelistedBuyer,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    )
        internal
        correctFeeRecipientsAndPercentages(
            _feeRecipients.length,
            _feePercentages.length
        )
        isFeePercentagesLessThanMaximum(_feePercentages)
    {
        if (_erc20Token != address(0)) {
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                .ERC20Token = _erc20Token;
        }
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .amount = _amount;
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .feePercentages = _feePercentages;
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .feeRecipients = _feeRecipients;
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .feePercentages = _feePercentages;
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .buyNowPrice = _buyNowPrice;
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .whitelistedBuyer = _whitelistedBuyer;
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftSeller = msg.sender;
    }

    function createSale(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _amount,
        address _erc20Token,
        uint128 _buyNowPrice,
        address _whitelistedBuyer,
        address[] memory _feeRecipients,
        uint32[] memory _feePercentages
    )
        external
        isNotAuctioningThisNFT(_nftContractAddress, _tokenId)
        priceGreaterThanZero(_buyNowPrice)
    {
        _ids.increment();
        uint256 id = _ids.current();
        //min price = 0
        _setupSale(
            _nftContractAddress,
            _tokenId,
            id,
            _amount,
            _erc20Token,
            _buyNowPrice,
            _whitelistedBuyer,
            _feeRecipients,
            _feePercentages
        );

        emit SaleCreated(
            _nftContractAddress,
            _tokenId,
            id,
            _amount,
            msg.sender,
            _erc20Token,
            _buyNowPrice,
            _whitelistedBuyer,
            _feeRecipients,
            _feePercentages
        );
        //check if buyNowPrice is meet and conclude sale, otherwise reverse the early bid
        if (_isABidMade(_nftContractAddress, _tokenId, id)) {
            if (
                //we only revert the underbid if the seller specifies a different
                //whitelisted buyer to the highest bidder
                _isHighestBidderAllowedToPurchaseNFT(
                    _nftContractAddress,
                    _tokenId,
                    id
                )
            ) {
                if (_isBuyNowPriceMet(_nftContractAddress, _tokenId, id)) {
                    _transferNftsToAuctionContract(
                        _nftContractAddress,
                        _tokenId,
                        id
                    );
                    _transferNftAndPaySeller(_nftContractAddress, _tokenId, id);
                }
            } else {
                _reverseAndResetPreviousBid(_nftContractAddress, _tokenId, id);
            }
        }
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║            SALES             ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔═════════════════════════════╗
      ║        BID FUNCTIONS        ║
      ╚═════════════════════════════╝*/

    /********************************************************************
     * Make bids with ETH or an ERC20 Token specified by the NFT seller.*
     * Additionally, a buyer can pay the asking price to conclude a sale*
     * of an NFT.                                                      *
     ********************************************************************/

    function _makeBid(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _erc20Token,
        uint128 _tokenAmount
    )
        internal
        // notNftSeller(_nftContractAddress, _tokenId, _auctionId) @todo stack too deep
        paymentAccepted(
            _nftContractAddress,
            _tokenId,
            _auctionId,
            _erc20Token,
            _tokenAmount
        )
        bidAmountMeetsBidRequirements(
            _nftContractAddress,
            _tokenId,
            _auctionId,
            _tokenAmount
        )
    {
        require(
            msg.sender !=
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftSeller,
            "Owner cannot bid on own NFT"
        );
        _reversePreviousBidAndUpdateHighestBid(
            _nftContractAddress,
            _tokenId,
            _auctionId,
            _tokenAmount
        );
        emit BidMade(
            _nftContractAddress,
            _tokenId,
            msg.sender,
            msg.value,
            _erc20Token,
            _tokenAmount
        );
        _updateOngoingAuction(_nftContractAddress, _tokenId, _auctionId);
    }

    function makeBid(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _erc20Token,
        uint128 _tokenAmount
    )
        external
        payable
        auctionOngoing(_nftContractAddress, _tokenId, _auctionId)
        onlyApplicableBuyer(_nftContractAddress, _tokenId, _auctionId)
    {
        _makeBid(_nftContractAddress, _tokenId,_auctionId,  _erc20Token, _tokenAmount);
    }

    function makeCustomBid(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _erc20Token,
        uint128 _tokenAmount,
        address _nftRecipient
    )
        external
        payable
        auctionOngoing(_nftContractAddress, _tokenId, _auctionId)
        notZeroAddress(_nftRecipient)
        onlyApplicableBuyer(_nftContractAddress, _tokenId, _auctionId)
    {
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftRecipient = _nftRecipient;
        _makeBid(_nftContractAddress, _tokenId, _auctionId, _erc20Token, _tokenAmount);
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║        BID FUNCTIONS         ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║       UPDATE AUCTION         ║
      ╚══════════════════════════════╝*/

    /***************************************************************
     * Settle an auction or sale if the buyNowPrice is met or set  *
     *  auction period to begin if the minimum price has been met. *
     ***************************************************************/
    function _updateOngoingAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal {
        if (_isBuyNowPriceMet(_nftContractAddress, _tokenId, _auctionId)) {
            _transferNftsToAuctionContract(_nftContractAddress, _tokenId, _auctionId);
            _transferNftAndPaySeller(_nftContractAddress, _tokenId, _auctionId);
            return;
        }
        //min price not set, nft not up for auction yet
        if (_isMinimumBidMade(_nftContractAddress, _tokenId, _auctionId)) {
            _transferNftsToAuctionContract(_nftContractAddress, _tokenId, _auctionId);
            _updateAuctionEnd(_nftContractAddress, _tokenId, _auctionId);
        }
    }

    function _updateAuctionEnd(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
    {
        //the auction end is always set to now + the bid period
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].auctionEnd =
            _getAuctionBidPeriod(_nftContractAddress, _tokenId, _auctionId) +
            uint64(block.timestamp);
        emit AuctionPeriodUpdated(
            _nftContractAddress,
            _tokenId,
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].auctionEnd
        );
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║       UPDATE AUCTION         ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║       RESET FUNCTIONS        ║
      ╚══════════════════════════════╝*/

    /*
     * Reset all auction related parameters for an NFT.
     * This effectively removes an EFT as an item up for auction
     */
    function _resetAuction(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
    {
        delete nftContractAuctions[_nftContractAddress][_tokenId][_auctionId];
    }

    /*
     * Reset all bid related parameters for an NFT.
     * This effectively sets an NFT as having no active bids
     */
    function _resetBids(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        internal
    {
        delete nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBidder;
        delete nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid;
        delete nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftRecipient;
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║       RESET FUNCTIONS        ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║         UPDATE BIDS          ║
      ╚══════════════════════════════╝*/
    /******************************************************************
     * Internal functions that update bid parameters and reverse bids *
     * to ensure contract only holds the highest bid.                 *
     ******************************************************************/
    function _updateHighestBid(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint128 _tokenAmount
    ) internal {
        address auctionERC20Token = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].ERC20Token;
        if (_isERC20Auction(auctionERC20Token)) {
            IERC20(auctionERC20Token).transferFrom(
                msg.sender,
                address(this),
                _tokenAmount
            );
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                .nftHighestBid = _tokenAmount;
        } else {
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                .nftHighestBid = uint128(msg.value);
        }
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftHighestBidder = msg.sender;
    }

    function _reverseAndResetPreviousBid(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal {
        address nftHighestBidder = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBidder;

        uint128 nftHighestBid = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid;
        _resetBids(_nftContractAddress, _tokenId, _auctionId);

        _payout(_nftContractAddress, _tokenId, _auctionId, nftHighestBidder, nftHighestBid);
    }

    function _reversePreviousBidAndUpdateHighestBid(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint128 _tokenAmount
    ) internal {
        address prevNftHighestBidder = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBidder;

        uint256 prevNftHighestBid = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid;
        _updateHighestBid(_nftContractAddress, _tokenId, _auctionId, _tokenAmount);

        if (prevNftHighestBidder != address(0)) {
            _payout(
                _nftContractAddress,
                _tokenId,
                _auctionId,
                prevNftHighestBidder,
                prevNftHighestBid
            );
        }
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║         UPDATE BIDS          ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║  TRANSFER NFT & PAY SELLER   ║
      ╚══════════════════════════════╝*/
    function _transferNftAndPaySeller(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId
    ) internal {
        address _nftSeller = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftSeller;
        address _nftHighestBidder = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBidder;
        uint256 _amount = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].amount;
        address _nftRecipient = _getNftRecipient(_nftContractAddress, _tokenId, _auctionId);
        uint128 _nftHighestBid = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid;

        _resetBids(_nftContractAddress, _tokenId, _auctionId);

        _payFeesAndSeller(
            _nftContractAddress,
            _tokenId,
            _auctionId,
            _nftSeller,
            _nftHighestBid
        );
        IERC1155(_nftContractAddress).safeTransferFrom(
            address(this),
            _nftRecipient,
            _tokenId,
            _amount,
            new bytes(0)
        );

        _resetAuction(_nftContractAddress, _tokenId, _auctionId);
        emit NFTTransferredAndSellerPaid(
            _nftContractAddress,
            _tokenId,
            _amount,
            _nftSeller,
            _nftHighestBid,
            _nftHighestBidder,
            _nftRecipient
        );
    }

    function _payFeesAndSeller(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _nftSeller,
        uint256 _highestBid
    ) internal {
        uint256 feesPaid;
        for (
            uint256 i = 0;
            i <
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                .feeRecipients
                .length;
            i++
        ) {
            uint256 fee = _getPortionOfBid(
                _highestBid,
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                    .feePercentages[i]
            );
            feesPaid = feesPaid + fee;
            _payout(
                _nftContractAddress,
                _tokenId,
                _auctionId,
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
                    .feeRecipients[i],
                fee
            );
        }
        _payout(
            _nftContractAddress,
            _tokenId,
            _auctionId,
            _nftSeller,
            (_highestBid - feesPaid)
        );
    }

    function _payout(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _recipient,
        uint256 _amount
    ) internal {
        address auctionERC20Token = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].ERC20Token;
        if (_isERC20Auction(auctionERC20Token)) {
            IERC20(auctionERC20Token).transfer(_recipient, _amount);
        } else {
            // attempt to send the funds to the recipient
            (bool success, ) = payable(_recipient).call{
                value: _amount,
                gas: 20000
            }("");
            // if it failed, update their credit balance so they can pull it later
            if (!success) {
                failedTransferCredits[_recipient] =
                    failedTransferCredits[_recipient] +
                    _amount;
            }
        }
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║  TRANSFER NFT & PAY SELLER   ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║      SETTLE & WITHDRAW       ║
      ╚══════════════════════════════╝*/
    function settleAuction(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        external
        isAuctionOver(_nftContractAddress, _tokenId, _auctionId)
    {
        _transferNftAndPaySeller(_nftContractAddress, _tokenId, _auctionId);
        emit AuctionSettled(_nftContractAddress, _tokenId, msg.sender);
    }

    function withdrawAuction(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        external
    {
        //only the NFT owner can prematurely close and auction
        require(
            IERC1155(_nftContractAddress).balanceOf(msg.sender, _tokenId) > 0,
            // IERC1155(_nftContractAddress).ownerOf(_tokenId) == msg.sender,
            "Not NFT owner"
        );
        _resetAuction(_nftContractAddress, _tokenId, _auctionId);
        emit AuctionWithdrawn(_nftContractAddress, _tokenId, msg.sender);
    }

    function withdrawBid(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        external
        minimumBidNotMade(_nftContractAddress, _tokenId, _auctionId)
    {
        address nftHighestBidder = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBidder;
        require(msg.sender == nftHighestBidder, "Cannot withdraw funds");

        uint128 nftHighestBid = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid;
        _resetBids(_nftContractAddress, _tokenId, _auctionId);

        _payout(_nftContractAddress, _tokenId, _auctionId, nftHighestBidder, nftHighestBid);

        emit BidWithdrawn(_nftContractAddress, _tokenId, msg.sender);
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║      SETTLE & WITHDRAW       ║
      ╚══════════════════════════════╝*/
    /**********************************/

    /*╔══════════════════════════════╗
      ║       UPDATE AUCTION         ║
      ╚══════════════════════════════╝*/
    function updateWhitelistedBuyer(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        address _newWhitelistedBuyer
    ) external onlyNftSeller(_nftContractAddress, _tokenId, _auctionId) {
        require(_isASale(_nftContractAddress, _tokenId, _auctionId), "Not a sale");
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].whitelistedBuyer = _newWhitelistedBuyer;
        //if an underbid is by a non whitelisted buyer,reverse that bid
        address nftHighestBidder = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBidder;
        uint128 nftHighestBid = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftHighestBid;
        if (nftHighestBid > 0 && !(nftHighestBidder == _newWhitelistedBuyer)) {
            //we only revert the underbid if the seller specifies a different
            //whitelisted buyer to the highest bider

            _resetBids(_nftContractAddress, _tokenId, _auctionId);

            _payout(
                _nftContractAddress,
                _tokenId,
                _auctionId,
                nftHighestBidder,
                nftHighestBid
            );
        }

        emit WhitelistedBuyerUpdated(
            _nftContractAddress,
            _tokenId,
            _newWhitelistedBuyer
        );
    }

    function updateMinimumPrice(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint128 _newMinPrice
    )
        external
        // onlyNftSeller(_nftContractAddress, _tokenId, _auctionId)
        minimumBidNotMade(_nftContractAddress, _tokenId, _auctionId)
        isNotASale(_nftContractAddress, _tokenId, _auctionId)
        priceGreaterThanZero(_newMinPrice)
        minPriceDoesNotExceedLimit(
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].buyNowPrice,
            _newMinPrice
        )
    {
        require(
            msg.sender ==
                nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].nftSeller,
            "Only nft seller"
        );
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .minPrice = _newMinPrice;

        emit MinimumPriceUpdated(_nftContractAddress, _tokenId, _newMinPrice);

        if (_isMinimumBidMade(_nftContractAddress, _tokenId, _auctionId)) {
            _transferNftsToAuctionContract(_nftContractAddress, _tokenId, _auctionId);
            _updateAuctionEnd(_nftContractAddress, _tokenId, _auctionId);
        }
    }

    function updateBuyNowPrice(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _auctionId,
        uint128 _newBuyNowPrice
    )
        external
        onlyNftSeller(_nftContractAddress, _tokenId, _auctionId)
        priceGreaterThanZero(_newBuyNowPrice)
        minPriceDoesNotExceedLimit(
            _newBuyNowPrice,
            nftContractAuctions[_nftContractAddress][_tokenId][_auctionId].minPrice
        )
    {
        nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .buyNowPrice = _newBuyNowPrice;
        emit BuyNowPriceUpdated(_nftContractAddress, _tokenId, _newBuyNowPrice);
        if (_isBuyNowPriceMet(_nftContractAddress, _tokenId, _auctionId)) {
            _transferNftsToAuctionContract(_nftContractAddress, _tokenId, _auctionId);
            _transferNftAndPaySeller(_nftContractAddress, _tokenId, _auctionId);
        }
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
        _transferNftsToAuctionContract(_nftContractAddress, _tokenId, _auctionId);
        _transferNftAndPaySeller(_nftContractAddress, _tokenId, _auctionId);
        emit HighestBidTaken(_nftContractAddress, _tokenId);
    }

    /*
     * Query the owner of an NFT deposited for auction
     */
    function ownerOfNFT(address _nftContractAddress, uint256 _tokenId, uint256 _auctionId)
        external
        view
        returns (address)
    {
        address nftSeller = nftContractAuctions[_nftContractAddress][_tokenId][_auctionId]
            .nftSeller;
        require(nftSeller != address(0), "NFT not deposited");

        return nftSeller;
    }

    /*
     * If the transfer of a bid has failed, allow the recipient to reclaim their amount later.
     */
    function withdrawAllFailedCredits() external {
        uint256 amount = failedTransferCredits[msg.sender];

        require(amount != 0, "no credits to withdraw");

        failedTransferCredits[msg.sender] = 0;

        (bool successfulWithdraw, ) = msg.sender.call{
            value: amount,
            gas: 20000
        }("");
        require(successfulWithdraw, "withdraw failed");
    }

    /**********************************/
    /*╔══════════════════════════════╗
      ║             END              ║
      ║       UPDATE AUCTION         ║
      ╚══════════════════════════════╝*/
    /**********************************/
}
