{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Xoken.Node.Data where

import Codec.Compression.GZip as GZ
import Codec.Serialise
import Conduit
import Control.Applicative
import Control.Arrow (first)
import Control.Monad
import Control.Monad.Trans.Maybe
import Data.Aeson as A
import qualified Data.Aeson.Encoding as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Base64.Lazy as B64L
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as C
import Data.ByteString.Short (ShortByteString)
import qualified Data.ByteString.Short as B.Short
import Data.Char (ord)
import Data.Default
import Data.Foldable
import Data.Functor.Identity
import Data.Hashable
import Data.Hashable.Time
import Data.Int
import qualified Data.IntMap as I
import Data.IntMap.Strict (IntMap)
import Data.Maybe
import Data.Serialize as S
import Data.String.Conversions
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as T.Lazy
import Data.Time.Clock (UTCTime)
import Data.Word
import qualified Database.CQL.IO as Q
import GHC.Generics
import Network.Socket (SockAddr(SockAddrUnix))
import Paths_xoken_node as P
import Prelude as P
import Text.Regex.TDFA
import UnliftIO
import UnliftIO.Exception
import qualified Web.Scotty.Trans as Scotty
import Xoken as H

encodeShort :: Serialize a => a -> ShortByteString
encodeShort = B.Short.toShort . S.encode

decodeShort :: Serialize a => ShortByteString -> a
decodeShort bs =
    case S.decode (B.Short.fromShort bs) of
        Left e -> P.error e
        Right a -> a

data RPCMessage
    = RPCRequest
          { rqMethod :: String
          , rqParams :: RPCReqParams
          }
    | RPCResponse
          { rsStatusCode :: Int16
          , rsResp :: Either RPCError (Maybe RPCResponseBody)
          }
    deriving (Show, Generic, Hashable, Eq, Serialise)

data RPCError
    = RPCError
        { rsStatusMessage :: RPCErrors
        , rsErrorData :: Maybe String
        }
    deriving (Show, Generic, Hashable, Eq, Serialise)

data XRPCRequest
    = CBORRPCRequest
          { reqId :: Int
          , method :: String
          , params :: RPCReqParams
          }
    | JSONRPCRequest
          { method :: String
          , params :: RPCReqParams
          , jsonrpc :: String
          , id :: Int
          }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance FromJSON XRPCRequest where
    parseJSON = genericParseJSON (defaultOptions {sumEncoding = UntaggedValue})

data XRPCResponse
    = CBORRPCResponse
          { matchId :: Int
          , statusCode :: Int16
          , statusMessage :: Maybe String
          , respBody :: Maybe RPCResponseBody
          }
    | JSONRPCSuccessResponse
          { jsonrpc :: String
          , result :: Maybe RPCResponseBody
          , id :: Int
          }
    | JSONRPCErrorResponse
          { id :: Int
          , error :: ErrorResponse
          , jsonrpc :: String
          }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance ToJSON XRPCResponse where
    toJSON = genericToJSON (defaultOptions {sumEncoding = UntaggedValue})

data ErrorResponse =
    ErrorResponse
        { code :: Int
        , message :: String
        , _data :: Maybe String
        }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance ToJSON ErrorResponse where
    toJSON (ErrorResponse c m d) = object ["code" .= c, "message" .= m, "data" .= d]

data RPCReqParams
    = AuthenticateReq
          { username :: String
          , password :: String
          }
    | GeneralReq
          { sessionKey :: String
          , methodParams :: Maybe RPCReqParams'
          }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance FromJSON RPCReqParams where
    parseJSON (Object o) =
        (AuthenticateReq <$> o .: "username" <*> o .: "password") <|>
        (GeneralReq <$> o .: "sessionKey" <*> o .:? "methodParams")

data RPCReqParams'
    = AddUser 
          { auUsername :: String
          , auApiExpiryTime :: Maybe UTCTime
          , auApiQuota :: Maybe Int32
          , auFirstName :: String
          , auLastName :: String
          , auEmail :: String
          , auRoles :: Maybe [String]
          } 
    | GetBlockByHeight
          { gbHeight :: Int
          }
    | GetBlocksByHeight
          { gbHeights :: [Int]
          }
    | GetBlockByHash
          { gbBlockHash :: String
          }
    | GetBlocksByHashes
          { gbBlockHashes :: [String]
          }
    | GetTxIDsByBlockHash
          { gtTxBlockHash :: String
          , gtPageSize :: Int32
          , gtPageNumber :: Int32
          }
    | GetTransactionByTxID
          { gtTxHash :: String
          }
    | GetTransactionsByTxIDs
          { gtTxHashes :: [String]
          }
    | GetRawTransactionByTxID
          { gtRTxHash :: String
          }
    | GetRawTransactionsByTxIDs
          { gtRTxHashes :: [String]
          }
    | GetOutputsByAddress
          { gaAddrOutputs :: String
          , gaPageSize :: Maybe Int32
          , gaNominalTxIndex :: Maybe Int64
          }
    | GetOutputsByAddresses
          { gasAddrOutputs :: [String]
          , gasPageSize :: Maybe Int32
          , gasNominalTxIndex :: Maybe Int64
          }
    | GetOutputsByScriptHash
          { gaScriptHashOutputs :: String
          , gaScriptHashPageSize :: Maybe Int32
          , gaScriptHashNominalTxIndex :: Maybe Int64
          }
    | GetOutputsByScriptHashes
          { gasScriptHashOutputs :: [String]
          , gasScriptHashPageSize :: Maybe Int32
          , gasScriptHashNominalTxIndex :: Maybe Int64
          }
    | GetMerkleBranchByTxID
          { gmbMerkleBranch :: String
          }
    | GetAllegoryNameBranch
          { gaName :: String
          , gaIsProducer :: Bool
          }
    | RelayTx
          { rTx :: ByteString
          }
    | GetPartiallySignedAllegoryTx
          { gpsaPaymentInputs :: [(OutPoint', Int)]
          , gpsaName :: ([Int], Bool) -- name & isProducer
          , gpsaOutputOwner :: String
          , gpsaOutputChange :: String
          }
    | GetTxOutputSpendStatus
          { gtssHash :: String
          , gtssIndex :: Int32
          }
    deriving (Generic, Show, Hashable, Eq, Serialise, ToJSON)

instance FromJSON RPCReqParams' where
    parseJSON (Object o) =
        (GetBlockByHeight <$> o .: "gbHeight") <|> (GetBlocksByHeight <$> o .: "gbHeights") <|>
        (GetBlockByHash <$> o .: "gbBlockHash") <|>
        (GetBlocksByHashes <$> o .: "gbBlockHashes") <|>
        (GetTxIDsByBlockHash <$> o .: "gtTxBlockHash" <*> o .:? "gtPageSize" .!= 100 <*>
         o .:? "gtPageNumber" .!= 1) <|>
        (GetTransactionByTxID <$> o .: "gtTxHash") <|>
        (GetTransactionsByTxIDs <$> o .: "gtTxHashes") <|>
        (GetRawTransactionByTxID <$> o .: "gtRTxHash") <|>
        (GetRawTransactionsByTxIDs <$> o .: "gtRTxHashes") <|>
        (GetOutputsByAddress <$> o .: "gaAddrOutputs" <*> o .:? "gaPageSize" <*> o .:? "gaNominalTxIndex") <|>
        (GetOutputsByAddresses <$> o .: "gasAddrOutputs" <*> o .:? "gasPageSize" <*> o .:? "gasNominalTxIndex") <|>
        (GetOutputsByScriptHash <$> o .: "gaScriptHashOutputs" <*> o .:? "gaScriptHashPageSize" <*>
         o .:? "gaScriptHashNominalTxIndex") <|>
        (GetOutputsByScriptHashes <$> o .: "gasScriptHashOutputs" <*> o .:? "gasScriptHashPageSize" <*>
         o .:? "gasScriptHashNominalTxIndex") <|>
        (GetMerkleBranchByTxID <$> o .: "gmbMerkleBranch") <|>
        (GetAllegoryNameBranch <$> o .: "gaName" <*> o .: "gaIsProducer") <|>
        (RelayTx . BL.toStrict . GZ.decompress . B64L.decodeLenient . BL.fromStrict . T.encodeUtf8 <$> o .: "rTx") <|>
        (GetPartiallySignedAllegoryTx <$> o .: "gpsaPaymentInputs" <*> o .: "gpsaName" <*> o .: "gpsaOutputOwner" <*>
         o .: "gpsaOutputChange") <|>
        (AddUser <$> o .: "username" <*> o .:? "api_expiry_time" <*> o .:? "api_quota" <*>
         o .: "first_name" <*> o .: "last_name" <*> o .: "email" <*> o .:? "roles") <|>
        (GetTxOutputSpendStatus <$> o .: "gtssHash" <*> o .: "gtssIndex")


data RPCResponseBody
    = AuthenticateResp
          { auth :: AuthResp
          }
    | RespAddUser
          { user :: AddUserResp
          }
    | RespBlockByHeight
          { block :: BlockRecord
          }
    | RespBlocksByHeight
          { blocks :: [BlockRecord]
          }
    | RespBlockByHash
          { block :: BlockRecord
          }
    | RespBlocksByHashes
          { blocks :: [BlockRecord]
          }
    | RespChainInfo
          { chainInfo :: ChainInfo
          }
    | RespTxIDsByBlockHash
          { txids :: [String]
          }
    | RespTransactionByTxID
          { tx :: TxRecord
          }
    | RespTransactionsByTxIDs
          { txs :: [TxRecord]
          }
    | RespRawTransactionByTxID
          { rawTx :: RawTxRecord
          }
    | RespRawTransactionsByTxIDs
          { rawTxs :: [RawTxRecord]
          }
    | RespOutputsByAddress
          { saddressOutputs :: [AddressOutputs]
          }
    | RespOutputsByAddresses
          { maddressOutputs :: [AddressOutputs]
          }
    | RespOutputsByScriptHash
          { sscriptOutputs :: [ScriptOutputs]
          }
    | RespOutputsByScriptHashes
          { mscriptOutputs :: [ScriptOutputs]
          }
    | RespMerkleBranchByTxID
          { merkleBranch :: [MerkleBranchNode']
          }
    | RespAllegoryNameBranch
          { nameBranch :: [(OutPoint', [MerkleBranchNode'])]
          }
    | RespRelayTx
          { rrTx :: Bool
          }
    | RespPartiallySignedAllegoryTx
          { psaTx :: ByteString
          }
    | RespTxOutputSpendStatus
          { spendStatus :: Maybe TxOutputSpendStatus
          }
    deriving (Generic, Show, Hashable, Eq, Serialise)

instance ToJSON RPCResponseBody where
    toJSON (AuthenticateResp a) = object ["auth" .= a]
    toJSON (RespAddUser usr) = object ["user" .= usr]
    toJSON (RespBlockByHeight b) = object ["block" .= b]
    toJSON (RespBlocksByHeight bs) = object ["blocks" .= bs]
    toJSON (RespBlockByHash b) = object ["block" .= b]
    toJSON (RespBlocksByHashes bs) = object ["blocks" .= bs]
    toJSON (RespChainInfo cw) = object ["chainwork" .= cw]
    toJSON (RespTxIDsByBlockHash txids) = object ["txids" .= txids]
    toJSON (RespTransactionByTxID tx) = object ["tx" .= tx]
    toJSON (RespTransactionsByTxIDs txs) = object ["txs" .= txs]
    toJSON (RespRawTransactionByTxID tx) = object ["rawTx" .= tx]
    toJSON (RespRawTransactionsByTxIDs txs) = object ["rawTxs" .= txs]
    toJSON (RespOutputsByAddress sa) = object ["saddressOutputs" .= sa]
    toJSON (RespOutputsByAddresses ma) = object ["maddressOutputs" .= ma]
    toJSON (RespOutputsByScriptHash sa) = object ["sscriptOutputs" .= sa]
    toJSON (RespOutputsByScriptHashes ma) = object ["mscriptOutputs" .= ma]
    toJSON (RespMerkleBranchByTxID mb) = object ["merkleBranch" .= mb]
    toJSON (RespAllegoryNameBranch nb) = object ["nameBranch" .= nb]
    toJSON (RespRelayTx rrTx) = object ["rrTx" .= rrTx]
    toJSON (RespPartiallySignedAllegoryTx ps) =
        object ["psaTx" .= (T.decodeUtf8 . BL.toStrict . B64L.encode . GZ.compress . BL.fromStrict $ ps)]
    toJSON (RespTxOutputSpendStatus ss) = object ["spendStatus" .= ss]

data AuthResp =
    AuthResp
        { sessionKey :: Maybe String
        , callsUsed :: Int
        , callsRemaining :: Int
        }
    deriving (Generic, Show, Hashable, Eq, Serialise, ToJSON)

data AddUserResp = 
    AddUserResp
        { aurUsername :: String
        , aurPassword :: String
        , aurFirstName :: String
        , aurLastName :: String
        , aurEmail :: String
        , aurRoles :: [String]
        , aurApiQuota :: Int
        , aurApiExpiryTime :: UTCTime
        }
    deriving (Generic, Show, Hashable, Eq, Serialise)

instance ToJSON AddUserResp where
    toJSON (AddUserResp uname pwd fname lname email roles apiQuota apiExpTime) =
        object
            [ "username" .= uname
            , "password" .= pwd
            , "first_name" .= fname
            , "last_name" .= lname
            , "email" .= email
            , "roles" .= roles
            , "api_quota" .= apiQuota
            , "api_expiry_time" .= apiExpTime
            ]

data ChainInfo =
    ChainInfo
        { ciChain :: String
        , ciChainWork :: String
        , ciDifficulty :: Double
        , ciHeaders :: Int32
        , ciBlocks :: Int32
        , ciBestBlockHash :: String
        } deriving (Generic, Show, Hashable, Eq, Serialise)

instance ToJSON ChainInfo where
    toJSON (ChainInfo ch cw diff hdr blk hs) =
        object
            [ "chain" .= ch
            , "chainwork" .= cw
            , "difficulty" .= diff
            , "headers" .= hdr
            , "blocks" .= blk
            , "bestBlockHash" .= hs
            ]

data BlockRecord =
    BlockRecord
        { rbHeight :: Int
        , rbHash :: String
        , rbHeader :: BlockHeader
        , rbNextBlockHash :: String
        , rbSize :: Int
        , rbTxCount :: Int
        , rbGuessedMiner :: String
        , rbCoinbaseMessage :: String
        , rbCoinbaseTx :: C.ByteString
        }
    deriving (Generic, Show, Hashable, Eq, Serialise)

instance ToJSON BlockRecord where
    toJSON (BlockRecord ht hs hdr nbhs size ct gm cm cb) =
        object
            [ "height" .= ht
            , "hash" .= hs
            , "header" .= hdr
            , "nextBlockHash" .= nbhs
            , "size" .= size
            , "txCount" .= ct
            , "guessedMiner" .= gm
            , "coinbaseMessage" .= cm
            , "coinbaseTx" .= (T.decodeUtf8 . BL.toStrict . B64L.encode . GZ.compress $ cb)
            ]

data RawTxRecord =
    RawTxRecord
        { txId :: String
        --, size :: Int32 -- number of bytes of serialized tx
        , txBlockInfo :: BlockInfo'
        , txSerialized :: C.ByteString
        , txOutputs :: [TxOutput]
        , txInputs :: [TxInput]
        , fees :: Int64
        }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance ToJSON RawTxRecord where
    toJSON (RawTxRecord tId tBI tS txo txi fees) =
        object
            [ "txId" .= tId
            , "size" .= C.length tS
            , "txBlockInfo" .= tBI
            , "txSerialized" .= (T.decodeUtf8 . BL.toStrict . B64L.encode . GZ.compress $ tS)
            , "txOutputs" .= txo
            , "txInputs" .= txi
            , "fees" .= fees
            ]

data TxRecord =
    TxRecord
        { txId :: String
        , txBlockInfo :: BlockInfo'
        , tx :: Tx
        , txOutputs :: [TxOutput]
        , txInputs :: [TxInput]
        , fees :: Int64
        }
    deriving (Show, Generic, Hashable, Eq, Serialise, ToJSON)

data TxInput =
    TxInput
        { outpointTxID :: String
        , outpointIndex :: Int32
        , txInputIndex :: Int32
        , address :: String  -- decode will succeed for P2PKH txn 
        , value :: Int64
        , unlockingScript :: String  -- scriptSig
        }
    deriving (Show, Generic, Hashable, Eq, Serialise, ToJSON)


data TxOutput = 
    TxOutput
        { outputIndex :: Int16 
        , address :: String -- decode will succeed for P2PKH txn 
        , spendingTxId :: Maybe String
        , spendingTxIdx :: Maybe Int32
        , isSpent :: Bool 
        , value :: Int64 
        , lockingScript :: String  -- Script Pub Key
        }
    deriving (Show, Generic, Hashable, Eq, Serialise, ToJSON)    

data TxOutputSpendStatus =
    TxOutputSpendStatus
          { isSpent :: Bool
          , spendingTxID :: Maybe String
          , spendingTxBlockHt :: Maybe Int32
          , spendingTxIndex :: Maybe Int32
          }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance ToJSON TxOutputSpendStatus where
    toJSON (TxOutputSpendStatus tis stxid stxht stxindex) =
        object
            [ "isSpent" .= tis
            , "spendingTxID" .= stxid
            , "spendingTxBlockHt" .= stxht
            , "spendingTxIndex" .= stxindex
            ]

data AddressOutputs =
    AddressOutputs
        { aoAddress :: String
        , aoOutput :: OutPoint'
        , aoBlockInfo :: BlockInfo'
        , aoNominalTxIndex :: Int64
        , aoIsOutputSpent :: Bool
        , aoPrevOutpoint :: [(OutPoint', Int32, Int64)]
        , aoValue :: Int64
        }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance ToJSON AddressOutputs where
    toJSON = genericToJSON (defaultOptions {fieldLabelModifier = drop 2})

data ScriptOutputs =
    ScriptOutputs
        { scScriptHash :: String
        , scOutput :: OutPoint'
        , scBlockInfo :: BlockInfo'
        , scNominalTxIndex :: Int64
        , scIsOutputSpent :: Bool
        , scPrevOutpoint :: [(OutPoint', Int32, Int64)]
        , scValue :: Int64
        }
    deriving (Show, Generic, Hashable, Eq, Serialise)

instance ToJSON ScriptOutputs where
    toJSON = genericToJSON (defaultOptions {fieldLabelModifier = drop 2})

data OutPoint' =
    OutPoint'
        { opTxHash :: String
        , opIndex :: Int32
        }
    deriving (Show, Generic, Hashable, Eq, Serialise, FromJSON, ToJSON)

data BlockInfo' =
    BlockInfo'
        { binfBlockHash :: String
        , binfTxIndex :: Int32
        , binfBlockHeight :: Int32
        }
    deriving (Show, Generic, Hashable, Eq, Serialise, ToJSON)

data MerkleBranchNode' =
    MerkleBranchNode'
        { nodeValue :: String
        , isLeftNode :: Bool
        }
    deriving (Show, Generic, Hashable, Eq, Serialise, ToJSON)

data PubNotifyMessage =
    PubNotifyMessage
        { psBody :: ByteString
        }
    deriving (Show, Generic, Eq, Serialise)

-- Internal message posting --
data XDataReq
    = XDataRPCReq
          { reqId :: Int
          , method :: String
          , params :: RPCReqParams
          , version :: Maybe String
          }
    | XDataRPCBadRequest
    | XCloseConnection
    deriving (Show, Generic, Hashable, Eq, Serialise)

data XDataResp =
    XDataRPCResp
        { matchId :: Int
        , statusCode :: Int16
        , statusMessage :: Maybe String
        , respBody :: Maybe RPCResponseBody
        }
    deriving (Show, Generic, Hashable, Eq, Serialise, ToJSON)

data RPCErrors
    = INVALID_METHOD
    | PARSE_ERROR
    | INVALID_PARAMS
    | INTERNAL_ERROR
    | SERVER_ERROR
    | INVALID_REQUEST
    deriving (Generic, Hashable, Eq, Serialise)

instance Show RPCErrors where
    show e =
        case e of
            INVALID_METHOD -> "Error: Invalid method"
            PARSE_ERROR -> "Error: Parse error"
            INVALID_PARAMS -> "Error: Invalid params"
            INTERNAL_ERROR -> "Error: RPC error occurred"
            SERVER_ERROR -> "Error: Something went wrong"
            INVALID_REQUEST -> "Error: Invalid request"

-- can be replaced with Enum instance but in future other RPC methods might be handled then we might have to give different codes
getJsonRPCErrorCode :: RPCErrors -> Int
getJsonRPCErrorCode err =
    case err of
        SERVER_ERROR -> -32000
        INVALID_REQUEST -> -32600
        INVALID_METHOD -> -32601
        INVALID_PARAMS -> -32602
        INTERNAL_ERROR -> -32603
        PARSE_ERROR -> -32700

addressToScriptOutputs :: AddressOutputs -> ScriptOutputs
addressToScriptOutputs AddressOutputs {..} =
    ScriptOutputs
        { scScriptHash = aoAddress
        , scOutput = aoOutput
        , scBlockInfo = aoBlockInfo
        , scNominalTxIndex = aoNominalTxIndex
        , scIsOutputSpent = aoIsOutputSpent
--        , scIsTypeReceive = aoIsTypeReceive
--        , scOtherAddress = aoOtherAddress
        , scPrevOutpoint = aoPrevOutpoint
        , scValue = aoValue
        }

coinbaseTxToMessage :: C.ByteString -> String
coinbaseTxToMessage s = case C.length (C.pack regex) > 6 of
    True -> let sig = C.drop 4 $ C.pack regex
                sigLen = fromIntegral . ord . C.head $ sig
                htLen = fromIntegral . ord . C.head . C.tail $ sig
            in C.unpack . C.take (sigLen - htLen - 1) . C.drop (htLen+2) $ sig
    False -> "False"
  where r :: String
        r = "\255\255\255\255[\NUL-\255]+"
        regex = ((C.unpack s) =~ r) :: String

        
validateEmail :: String -> Bool
validateEmail email = let emailRegex = "^[a-zA-Z0-9+._-]+@[a-zA-Z-]+\\.[a-z]+$" :: String
                      in (email =~ emailRegex :: Bool) || (null email)

