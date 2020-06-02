import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit
import SyncCore

public enum RequestChatContextResultsError {
    case generic
    case locationRequired
}

public final class CachedChatContextResult: PostboxCoding {
    public let data: Data
    public let timestamp: Int32
    
    public init(data: Data, timestamp: Int32) {
        self.data = data
        self.timestamp = timestamp
    }
    
    public init(decoder: PostboxDecoder) {
        self.data = decoder.decodeDataForKey("data") ?? Data()
        self.timestamp = decoder.decodeInt32ForKey("timestamp", orElse: 0)
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeData(self.data, forKey: "data")
        encoder.encodeInt32(self.timestamp, forKey: "timestamp")
    }
}

private let collectionSpec = ItemCacheCollectionSpec(lowWaterItemCount: 40, highWaterItemCount: 60)

private struct RequestData: Codable {
    let version: String
    let botId: PeerId
    let peerId: PeerId
    let query: String
}

private let requestVersion = "3"

public struct RequestChatContextResultsResult {
    public let results: ChatContextResultCollection
    public let isStale: Bool
    
    public init(results: ChatContextResultCollection, isStale: Bool) {
        self.results = results
        self.isStale = isStale
    }
}

public func requestChatContextResults(account: Account, botId: PeerId, peerId: PeerId, query: String, location: Signal<(Double, Double)?, NoError> = .single(nil), offset: String, incompleteResults: Bool = false, staleCachedResults: Bool = false) -> Signal<RequestChatContextResultsResult?, RequestChatContextResultsError> {
    return account.postbox.transaction { transaction -> (bot: Peer, peer: Peer)? in
        if let bot = transaction.getPeer(botId), let peer = transaction.getPeer(peerId) {
            return (bot, peer)
        } else {
            return nil
        }
    }
    |> mapToSignal { botAndPeer -> Signal<((bot: Peer, peer: Peer)?, (Double, Double)?), NoError> in
        if let (bot, _) = botAndPeer, let botUser = bot as? TelegramUser, let botInfo = botUser.botInfo, botInfo.flags.contains(.requiresGeolocationForInlineRequests) {
            return location
            |> take(1)
            |> map { location -> ((bot: Peer, peer: Peer)?, (Double, Double)?) in
                return (botAndPeer, location)
            }
        } else {
            return .single((botAndPeer, nil))
        }
    }
    |> castError(RequestChatContextResultsError.self)
    |> mapToSignal { botAndPeer, location -> Signal<RequestChatContextResultsResult?, RequestChatContextResultsError> in
        guard let (bot, peer) = botAndPeer, let inputBot = apiInputUser(bot) else {
            return .single(nil)
        }
        
        return account.postbox.transaction { transaction -> Signal<RequestChatContextResultsResult?, RequestChatContextResultsError> in
            var staleResult: RequestChatContextResultsResult?
            
            if offset.isEmpty && location == nil {
                let requestData = RequestData(version: requestVersion, botId: botId, peerId: peerId, query: query)
                if let keyData = try? JSONEncoder().encode(requestData) {
                    let key = ValueBoxKey(MemoryBuffer(data: keyData))
                    if let cachedEntry = transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedContextResults, key: key)) as? CachedChatContextResult {
                        if let cachedResult = try? JSONDecoder().decode(ChatContextResultCollection.self, from: cachedEntry.data) {
                            let timestamp = Int32(Date().timeIntervalSince1970)
                            if cachedEntry.timestamp + cachedResult.cacheTimeout > timestamp {
                                return .single(RequestChatContextResultsResult(results: cachedResult, isStale: false))
                            } else if staleCachedResults {
                                let staleCollection = ChatContextResultCollection(
                                    botId: cachedResult.botId,
                                    peerId: cachedResult.peerId,
                                    query: cachedResult.query,
                                    geoPoint: cachedResult.geoPoint,
                                    queryId: cachedResult.queryId,
                                    nextOffset: nil,
                                    presentation: cachedResult.presentation,
                                    switchPeer: cachedResult.switchPeer,
                                    results: cachedResult.results,
                                    cacheTimeout: 0
                                )
                                staleResult = RequestChatContextResultsResult(results: staleCollection, isStale: true)
                            }
                        }
                    }
                }
            }
            
            var flags: Int32 = 0
            var inputPeer: Api.InputPeer = .inputPeerEmpty
            var geoPoint: Api.InputGeoPoint?
            if let actualInputPeer = apiInputPeer(peer) {
                inputPeer = actualInputPeer
            }
            if let (latitude, longitude) = location {
                flags |= (1 << 0)
                geoPoint = Api.InputGeoPoint.inputGeoPoint(lat: latitude, long: longitude)
            }
            
            var signal: Signal<RequestChatContextResultsResult?, RequestChatContextResultsError> = account.network.request(Api.functions.messages.getInlineBotResults(flags: flags, bot: inputBot, peer: inputPeer, geoPoint: geoPoint, query: query, offset: offset))
            |> map { result -> ChatContextResultCollection? in
                return ChatContextResultCollection(apiResults: result, botId: bot.id, peerId: peerId, query: query, geoPoint: location)
            }
            |> mapError { error -> RequestChatContextResultsError in
                if error.errorDescription == "BOT_INLINE_GEO_REQUIRED" {
                    return .locationRequired
                } else {
                    return .generic
                }
            }
            |> mapToSignal { result -> Signal<RequestChatContextResultsResult?, RequestChatContextResultsError> in
                guard let result = result else {
                    return .single(nil)
                }
                
                return account.postbox.transaction { transaction -> RequestChatContextResultsResult? in
                    if result.cacheTimeout > 10 {
                        if let resultData = try? JSONEncoder().encode(result) {
                            let requestData = RequestData(version: requestVersion, botId: botId, peerId: peerId, query: query)
                            if let keyData = try? JSONEncoder().encode(requestData) {
                                let key = ValueBoxKey(MemoryBuffer(data: keyData))
                                transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedContextResults, key: key), entry: CachedChatContextResult(data: resultData, timestamp: Int32(Date().timeIntervalSince1970)), collectionSpec: collectionSpec)
                            }
                        }
                    }
                    return RequestChatContextResultsResult(results: result, isStale: false)
                }
                |> castError(RequestChatContextResultsError.self)
            }
            
            if incompleteResults {
                signal = .single(staleResult) |> then(signal)
            }
            
            return signal
        }
        |> castError(RequestChatContextResultsError.self)
        |> switchToLatest
    }
}
