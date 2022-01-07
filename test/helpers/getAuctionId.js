module.exports = async tx =>  (await tx.wait())
  ?.events
  .find(event => ['NftAuctionCreated', 'SaleCreated'].includes(event.event))
  ?.args.id.toNumber()