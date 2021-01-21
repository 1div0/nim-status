import callrpc, conversions

import web3, json, strutils, strformat, sequtils
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
  BlockSeq = seq[int]
  Address = string
  TransferType* = enum
    eth, erc20
  TransferView* = ref object 
    # we need to assign our own id because txHash is too ambitious fro ERC20 transfers 
    #ID          common.Hash    `json:"id"`
    id*: string
    # type "eth" or "erc20"
    #Type        TransferType   `json:"type"`
    transferType*: TransferType
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
    gasPrice*: int
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
    txStatus*: int
    # retrieved via `eth_getTransactionByHash`
    #Input       hexutil.Bytes  `json:"input"`
    input*: string
    # retrieved via `eth_getBlockByNumber` or `eth_getLogs`
    #TxHash      common.Hash    `json:"txHash"`
    txHash*: string
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
# as it could've happened that several txs balanced themselves out
proc findBlockWithBalanceChange(address: Address, blockRange: BlockRange): int =
  var fromBlock = blockRange[0]
  var toBlock = blockRange[1]
  var blockNumber = toBlock
  let targetBalance = getValueForBlock(address, intToHex(toBlock), RemoteMethod.eth_getBalance)
  blockNumber = findLowestBlockNumber(address, [fromBlock, toBlock], 
                         RemoteMethod.eth_getBalance, targetBalance)

  # Check if there were no txs in [blockNumber, toBlock]
  # Note that eth_getTransactionCount only counts outgoing transactions
  let txCount1 = getValueForBlock(address, intToHex(blockNumber), RemoteMethod.eth_getTransactionCount)
  let txCount2 = getValueForBlock(address, intToHex(toBlock), RemoteMethod.eth_getTransactionCount)
  if txCount1 == txCount2:
    # No txs occurred in between [blockNumber, toBlock]
    result = blockNumber
  else:
    # At least several txs occurred, so we find the number
    # of the lowest block containing txCount2
    blockNumber = findLowestBlockNumber(address, [fromBlock, toBlock], 
                        RemoteMethod.eth_getTransactionCount, txCount2)
    let balance = getValueForBlock(address, intToHex(blockNumber), RemoteMethod.eth_getBalance)
    if balance == targetBalance:
      # This was the tx setting targetbalance
      result = blockNumber
    else:
      # This means there must have been an incoming tx inside [blockNumber, toBlock]
      result = findLowestBlockNumber(address, [blockNumber, toBlock], 
                         RemoteMethod.eth_getBalance, targetBalance)


# We need to find exact block numbers containing balance changes
proc balanceBinarySearch(address: Address, blockRange: BlockRange): BlockSeq =
  var blockNumbers: BlockSeq = @[]
  var fromBlock = blockRange[0]
  var toBlock = blockRange[1]
  while fromBlock < toBlock and len(blockNumbers) < 20:
    let blockNumber = findBlockWithBalanceChange(address, [fromBlock, toBlock])
    blockNumbers.add(blockNumber)

    toBlock = blockNumber - 1

  result = blockNumbers

var txToData = initTable[string, TransferView]()

# Find blocks with balance changes and extract tx hashes from info
# fetched via eth_getBlockByNumber
proc findEthTxHashes(address: Address, txBlockRange: BlockRange, txToData: var TransferMap) =
  # Find block numbers containing balance changes
  var blockNumbers: BlockSeq = balanceBinarySearch(address, txBlockRange)

  # Get block info and extract txs pertaining to given address
  for n in items(blockNumbers):
    let blockNumber = intToHex(n)
    let jsonNode = parseJSON(fmt"""["{blockNumber}", true]""")
    let resp = callRPC(web3Obj, RemoteMethod.eth_getBlockByNumber, jsonNode)

    let blockHash = resp.result["hash"].getStr
    let timestamp = fromHex[int](resp.result["timestamp"].getStr)
    for tx in items(resp.result["transactions"]):
      if tx["from"].getStr == address or tx["to"].getStr == address:
        let txHash = tx["hash"].getStr
        let trView = TransferView(
          transferType: TransferType.eth,
          address: address,
          blockNumber: n, 
          blockHash: blockHash,
          timestamp: timestamp,
          txHash: txHash)
        txToData[txHash] = trView


let transferEventSignatureHash = $keccak_256.digest("Transfer(address,address,int256)")
# We have to invoke eth_getLogs twice for both
# incoming and outgoing ERC-20 transfers
proc fetchErc20Logs(address: Address, blockRange: BlockRange, txToData: var TransferMap) =
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

  var logs: seq[JsonNode] = concat(incomingLogs.result.getElems, outgoingLogs.result.getElems)
  for obj in logs:
    let txHash = obj["transactionHash"].getStr
    let blockNumber = fromHex[int](obj["blockNumber"].getStr)
    let blockHash = obj["blockHash"].getStr
    let trView = TransferView(
      transferType: TransferType.erc20,
      address: address,
      blockNumber: blockNumber,
      blockHash: blockHash,
      txHash: txHash 
      )
    txToData[txHash] = trView

  
proc fetchTxDetails(address: Address, txToData: TransferMap) =
  for tx in txToData.keys:
    let jsonNode = parseJSON(fmt"""["{tx}"]""")
    let txInfo = callRPC(web3Obj, RemoteMethod.eth_getTransactionByHash, jsonNode)
    let txReceipt = callRPC(web3Obj, RemoteMethod.eth_getTransactionReceipt, jsonNode)

    let trView = txToData[tx]
    trView.gasPrice = fromHex[int](txInfo.result["gasPrice"].getStr)
    trView.gasLimit = fromHex[int](txInfo.result["gas"].getStr)
    trView.gasUsed = fromHex[int](txReceipt.result["gasUsed"].getStr)
    trView.nonce = fromHex[int](txInfo.result["nonce"].getStr)
    trView.txStatus = fromHex[int](txReceipt.result["status"].getStr)
    trView.input = txInfo.result["input"].getStr
    trView.value = fromHex[int](txInfo.result["value"].getStr)
    trView.fromAddr = txInfo.result["from"].getStr
    trView.toAddr = txInfo.result["to"].getStr

proc fetchTxHistory*(address: Address): TransferMap = 
  var txToData = TransferMap()

  # Find block range that we will search for balance changes
  let txBlockRange: BlockRange = txBinarySearch(address)
  if txBlockRange == [0, 0]:
    # No txs found
    return txToData

  findEthTxHashes(address, txBlockRange, txToData)
  fetchErc20Logs(address, txBlockRange, txToData)

  fetchTxDetails(address, txToData)

  result = txToData
