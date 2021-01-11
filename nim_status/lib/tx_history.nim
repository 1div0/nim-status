import callrpc, conversions

import web3, json, strutils, strformat
import json_rpc/client
import nimcrypto
import tables

#import # nim-status libs
  #../[settings, database, conversions, tx_history, callrpc]
  #
  #
const txsPerPage = 20
const ethTransferType = "eth"
const erc20TransferType = "erc20"

type 
  BlockRange = array[2, int]
  Address = string
  TransferView* = ref object 
    # we need to assign our own id because txHash is too ambitious fro ERC20 transfers 
    #ID          common.Hash    `json:"id"`
    id*: string
    # type "eth" or "erc20"
    #Type        TransferType   `json:"type"`
    transferType*: string
    # not completely sure what this one means 
    #Address     common.Address `json:"address"`
    address*: Address
    # is known after range scan
    # BlockNumber *hexutil.Big   `json:"blockNumber"`
    blockNumber*: int
    # retrieved via `eth_getBlockByNumber`
    # BlockHash   common.Hash    `json:"blockhash"`
    blockHash*: string
    # retrieved via `eth_getBlockByNumber`
    #Timestamp   hexutil.int64 `json:"timestamp"`
    timestamp*: int
    # retrieved via `eth_getTransactionByHash`
    #GasPrice    *hexutil.Big   `json:"gasPrice"`
    gasPrice*:int
    # retrieved via `eth_getTransactionByHash`
    #GasLimit    hexutil.int64 `json:"gasLimit"`
    gasLimit*: int64
    # retrieved via `eth_getTransactionReceipt`
    #GasUsed     hexutil.int64 `json:"gasUsed"`
    gasUsed*: int64
    # retrieved via `eth_getTransactionByHash`
    #Nonce       hexutil.int64 `json:"nonce"`
    nonce*: int64
    # retrieved via `eth_getTransactionReceipt`
    #TxStatus    hexutil.int64 `json:"txStatus"`
    txStatus*: int64
    # retrieved via `eth_getTransactionByHash`
    #Input       hexutil.Bytes  `json:"input"`
    input*: seq[byte]
    # retrieved via `eth_getBlockByNumber` or `eth_getLogs`
    #TxHash      common.Hash    `json:"txHash"`
    txHash*:string
    # retrieved via `eth_getTransactionByHash` or `eth_getLogs`
    #Value       *hexutil.Big   `json:"value"`
    value*: int
    # retrieved via `eth_getTransactionByHash` or `eth_getLogs`
    #From        common.Address `json:"from"`
    fromAddr*: Address
    # retrieved via `eth_getTransactionByHash` or `eth_getLogs`
    #To          common.Address `json:"to"`
    toAddr*: Address
    # retrieved via `eth_getTransactionReceipt` or `eth_getLogs`
    #Contract    common.Address `json:"contract"`
    contract*: Address
    #NetworkID   int64
    networkID*:   int64

  TransferMap* = Table[string, TransferView]

var web3Obj: Web3

proc setWeb3Obj*(web3: Web3) = 
  web3Obj = web3

# blockNumber can be either "earliest", "latest", "pending", or hex-encoding int
proc getValueForBlock(address: Address, blockNumber: string, methodName: RemoteMethod): int = 

  let jsonNode = parseJson(fmt"""["{address}", "{blockNumber}"]""")
  let resp = callRPC(web3Obj, methodName, jsonNode)
  let txCount = fromHex[int](resp.result.getStr)

  return txCount

# Find lowest block number for which a condition
# procPtr(address, blockNumber) >= targetValue holds
proc findLowestBlockNumber(address: Address, 
                           blockRange: BlockRange, 
                           methodName: RemoteMethod, targetValue: int): int = 
  var fromBlock = blockRange[0]
  var toBlock = blockRange[1]
  var blockNumber = fromBlock
  while toBlock != fromBlock:
    blockNumber = (toBlock + fromBlock) /% 2
    let blockNumberHex: string = intToHex(blockNumber)
    let value = getValueForBlock(address, blockNumberHex, methodName)
    if value >= targetValue:
      toBlock = blockNumber
    else:
      fromBlock = blockNumber + 1

  result = fromBlock

# Find a block range with minimum txsPerPage transactions
proc txBinarySearch*(address: Address): BlockRange =
  let totalTxCount = getValueForBlock(address, "latest", RemoteMethod.eth_getTransactionCount)
  if totalTxCount == 0:
    return [0, 0]

  # Get last block number
  var jsonNode = parseJSON("""[]""")
  var resp = callRPC(web3Obj, RemoteMethod.eth_blockNumber, jsonNode)
  let lastBlockNumber = fromHex[int](resp.result.getStr)


  # Find upper bound (number of the block containing last tx)
  # This means finding the lowest blockNumber containing totalTxCount txs
  # let rightBlock = findLowestBlockNumber(address, @[0, lastBlockNumber], 
  #                         getTxCountForBlock, totalTxCount)

  var leftBlock = 0
  if totalTxCount > 20:
    # Find lower bound (number of the block containing lowerTxBound txs
    # This means finding lowest block number containing lowerTxBound txs
    let lowerTxBound = totalTxCount - 19
    leftBlock = findLowestBlockNumber(address, [0, lastBlockNumber], 
                          RemoteMethod.eth_getTransactionCount, lowerTxBound)
  #else:
    # No need to restrict block range, as there can be incoming transactions
    # anywhere inside the whole range

  return [leftBlock, lastBlockNumber]




# First, we find a lowest block number with balance
# equal to that of toBlock
# Then we check if there were any outgoing txs between it and the last block,
# as it could've been that several txs balanced themselves out
proc findBlockWithBalanceChange(address: Address, blockRange: BlockRange): int =
  var fromBlock = blockRange[0]
  var toBlock = blockRange[1]
  var blockNumber = toBlock
  let targetBalance = getValueForBlock(address, intToHex(toBlock), RemoteMethod.eth_getBalance)
  blockNumber = findLowestBlockNumber(address, [fromBlock, toBlock], 
                         RemoteMethod.eth_getBalance, targetBalance)

  # Check if there were no txs in [blockNumber, rightBlock]
  let txCount1 = getValueForBlock(address, intToHex(blockNumber), RemoteMethod.eth_getTransactionCount)
  let txCount2 = getValueForBlock(address, intToHex(blockRange[1]), RemoteMethod.eth_getTransactionCount)
  if txCount1 == txCount2:
    result = blockNumber
  else:
    result = findLowestBlockNumber(address, [fromBlock, toBlock], 
                        RemoteMethod.eth_getTransactionCount, txCount2)


# We need to find exact block numbers containing balance changes
proc balanceBinarySearch(address: Address, blockRange: BlockRange): seq[int] =
  var blockNumbers: seq[int] = @[]
  var fromBlock = blockRange[0]
  var toBlock = blockRange[1]
  while fromBlock < toBlock and len(blockNumbers) < 20:
    let blockNumber = findBlockWithBalanceChange(address, [fromBlock, toBlock])
    blockNumbers.add(blockNumber)

    toBlock = blockNumber - 1

  result = blockNumbers

let transferEventSignatureHash = $keccak_256.digest("Transfer(address,address,int256)")
var txToData = initTable[string, TransferView]()

# We have to invoke eth_getLogs twice for both
# incoming and outgoing ERC-20 transfers
proc erc20Logs(address: Address, blockRange: BlockRange, txToData: var TransferMap) =
  let fromBlock = blockRange[0]
  let toBlock = blockRange[1]
  var jsonNode = parseJson(fmt"""[{{  
    "fromBlock": "{fromBlock}", 
    "toBlock": "{toBlock}",
    "topics": ["{transferEventSignatureHash}", "", "{address}"]}}]""")
  var incomingLogs = callRPC(web3Obj, RemoteMethod.eth_getLogs, jsonNode)
  jsonNode = parseJson(fmt"""[{{  
    "fromBlock": "{fromBlock}", 
    "toBlock": "{toBlock}",
    "topics": ["{transferEventSignatureHash}", "{address}", ""]}}]""")

  var outgoingLogs = callRPC(web3Obj, RemoteMethod.eth_getLogs, jsonNode)

  var txHashes: seq[string] = @[]
  for obj in incomingLogs.result:
    let txHash = obj["transactionHash"].getStr
    let blockNumber = fromHex[int](obj["blockNumber"].getStr)
    let blockHash = obj["blockHash"].getStr
    let trView = TransferView(
      txHash: txHash, 
      blockNumber: blockNumber,
      transferType: erc20TransferType,
      blockHash: blockHash)
    txToData[txHash] = trView

  for obj in outgoingLogs.result:
    let txHash = obj["transactionHash"].getStr
    let blockNumber = fromHex[int](obj["blockNumber"].getStr)
    let blockHash = obj["blockHash"].getStr
    let trView = TransferView(
      txHash: txHash, 
      blockNumber: blockNumber,
      transferType: erc20TransferType,
      blockHash: blockHash)
    txToData[txHash] = trView


proc findEthTxHashes(address: Address, txBlockRange: BlockRange, txToData: var TransferMap) =
  # Find block numbers containing balance changes
  var blockNumbers: seq[int] = balanceBinarySearch(address, txBlockRange)

  for n in items(blockNumbers):
    let blockNumber = intToHex(n)
    let jsonNode = parseJSON(fmt"""[{blockNumber}, false]""")
    let resp = callRPC(web3Obj, RemoteMethod.eth_getBlockByNumber, jsonNode)
    for tx in items(resp.result["transactions"]):
      let txHash = tx.getStr
      let trView = TransferView(blockNumber: n, txHash: txHash)
      txToData[txHash] = trView

  
proc fetchTxDetails(address: Address, txToData: TransferMap) =
  for tx in txToData.keys:
    let jsonNode = parseJSON(fmt"""["{tx}"]""")
    let txInfo = callRPC(web3Obj, RemoteMethod.eth_getTransactionByHash, jsonNode)
    let txReceipt = callRPC(web3Obj, RemoteMethod.eth_getTransactionReceipt, jsonNode)

    # let transferView = TransferView(
    #   transferType: "eth",
    #   address: address,
    #   blockNumber

    # )

proc fetchTxHistory(address: Address): TransferMap = 
  var txToData = TransferMap()

  # Find block range that we will search for balance changes
  let txBlockRange: BlockRange = txBinarySearch(address)
  findEthTxHashes(address, txBlockRange, txToData)
  erc20Logs(address, txBlockRange, txToData)

  fetchTxDetails(address, txToData)

  result = txToData
