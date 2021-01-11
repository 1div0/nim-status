import # nim libs
  os, json, options, strutils, strformat

import # vendor libs
  sqlcipher, json_serialization, web3/conversions as web3_conversions

import # nim-status libs
  ../../nim_status/lib/[settings, database, conversions, tx_history, callrpc]


let passwd = "qwerty"
let path = currentSourcePath.parentDir() & "/build/myDatabase"
let db = initializeDB(path, passwd)
#f315575765b14720b32382a61a89341a
let settingsStr = """{
    "address": "0x1122334455667788990011223344556677889900",
    "networks/current-network": "mainnet_rpc",
    "dapps-address": "0x1122334455667788990011223344556677889900",
    "eip1581-address": "0x1122334455667788990011223344556677889900",
    "installation-id": "ABC-DEF-GHI",
    "key-uid": "XYZ",
    "latest-derived-path": 0,
    "networks/networks": [{"id":"mainnet_rpc","etherscan-link":"https://etherscan.io/address/","name":"Mainnet with upstream RPC","config":{"NetworkId":1,"DataDir":"/ethereum/mainnet_rpc","UpstreamConfig":{"Enabled":true,"URL":"wss://mainnet.infura.io/ws/v3/7230123556ec4a8aac8d89ccd0dd74d7"}}}],
    "photo-path": "ABXYZC",

    "preview-privacy?": false,
    "public-key": "0x123",
    "signing-phrase": "ABC DEF GHI"
  }"""

let settingsObj = JSON.decode(settingsStr, Settings, allowUnknownFields = true)
let web3Obj = newWeb3(settingsObj)

var jsonNode = parseJSON("""[]""")
var resp = callRPC(web3Obj, eth_blockNumber, jsonNode)
echo "eth_blockNumber response", resp
var latestBlockNumber = fromHex[int](resp.result.getStr)
var blockNumber = intToHex(latestBlockNumber /% 2) # intToHex(blockNumber/%2)
echo "blockNumber, ", blockNumber

jsonNode = parseJson(fmt"""["0x111d500fe567696D0224A7292D47AF11e8A4bCB4", "{blockNumber}"]""")
echo "jsonNode ", jsonNode
resp = callRPC(web3Obj, eth_getTransactionCount, jsonNode)
echo "eth_getTransactionCount Response ", resp

jsonNode = parseJson(fmt"""["0x111d500fe567696D0224A7292D47AF11e8A4bCB4", "{blockNumber}"]""")
echo "jsonNode ", jsonNode
resp = callRPC(web3Obj, eth_getTransactionCount, jsonNode)
echo "eth_getTransactionCount Response ", resp

resp = callRPC(web3Obj, eth_getBalance, jsonNode)
echo "eth_getBalance Response ", resp

let fromBlock = intToHex(latestBlockNumber - 1)
let toBlock = intToHex(latestBlockNumber)

jsonNode = parseJson("""[{"address": "0xedae1aaa4f1ba708a30ecf8f5e64551aca403850", "fromBlock": "0x0", "toBlock": "latest"}]""")
resp = callRPC(web3Obj, eth_getLogs, jsonNode)
echo "eth_getLogs Response ", resp


db.close()
removeFile(path)
