import Vapor
import Foundation
import Cache

public final class Translate {
    
    let application: Application
    let config: TranslateConfig
    var translations: [String: Translation] = [:]
    var attempts: [String: TranslationAttempt] = [:]

    var cache: CacheProtocol? {
        return application.cache
    }

    func assertCache() throws -> CacheProtocol {
        guard let cache = cache else {
            throw Abort(.internalServerError, reason: "Cache is not set up")
        }
        return cache
    }
    
    public enum Platforms: String {
        case backend = "backend"
        case api = "api"
        case web = "web"
        case mobile = "mobile"
    }
    
    public init(application: Application) {
        self.application = application
        config = application.nStackConfig.translate
    }
    
    public final func get(platform: String, language: String, section: String, key: String, replace: [String: String]) -> String {
        application.nStackConfig.log("Requesting translate for platform: \(platform) - language: \(language) - section: \(section) - key: \(key)")
        do {
            // Fetch
            let translation = try fetch(platform: platform, language: language)
            
            // Retrieve value
            var value = translation.get(section: section, key: key)
            
            // Replace
            for(replaceKey, replaceValue) in replace {
                value = value.replacingOccurrences(of: "{" + replaceKey + "}", with: replaceValue)
            }
            
            return value

        } catch {
            return Translation.fallback(section: section, key: key)
        }
    }
    
    public final func get(platform: Platforms, language: String, section: String, key: String, replace: [String: String]) -> String {
        return get(platform: platform.rawValue, language: language, section: section, key: key, replace: replace)
    }
    
    public final func get(platform: Platforms, section: String, key: String, replace: [String: String]) -> String {
        return get(platform: platform.rawValue, language: config.defaultLanguage, section: section, key: key, replace: replace)
    }
    
    public final func get(platform: Platforms, section: String, key: String) -> String {
        return get(platform: platform.rawValue, language: config.defaultLanguage, section: section, key: key, replace: [:])
    }
    
    public final func get(section: String, key: String) -> String {
        return get(platform: config.defaultPlatform, language: config.defaultLanguage, section: section, key: key, replace: [:])
    }
    
    public final func get(section: String, key: String, replace: [String: String]) -> String {
        return get(platform: config.defaultPlatform, language: config.defaultLanguage, section: section, key: key, replace: replace)
    }
    
    public final func get(language: String, section: String, key: String) -> String {
        return get(platform: config.defaultPlatform, language: language, section: section, key: key, replace: [:])
    }
    
    public final func get(language: String, section: String, key: String, replace: [String: String]) -> String {
        return get(platform: config.defaultPlatform, language: language, section: section, key: key, replace: replace)
    }
    
    public final func get(section: String, language: String? = nil) throws -> Node {
        let locale: String = language ?? config.defaultLanguage

        application.nStackConfig.log("Requesting translate for platform: \(config.defaultPlatform) - language: \(locale) - section: \(section)")

        let translate: Translation = try self.fetch(
            platform: config.defaultPlatform,
            language: locale
        )

        return translate.get(section: section)
    }

    private final func fetch(platform: String, language: String) throws -> Translation {
        let cacheKey = Translate.cacheKey(platform: platform, language: language)
        
        // Look up attempt
        if let attempt: TranslationAttempt = attempts[cacheKey], attempt.avoidFetchingAgain(){
            application.nStackConfig.log("Failed lately, not reason to try again")
            
            // Try drop cache
            if let cacheTranslate = freshFromCache(platform: platform, language: language) {
                application.nStackConfig.log("Drop cache used as fallback")
                return cacheTranslate
            }
            
            application.nStackConfig.log("Failed lately and no cache")
            throw Abort(
                .internalServerError,
                metadata: nil,
                reason: "Failed lately and no cache to read from"
            )
        }
        
        // Try memory cache
        if let memoryTranslate = freshFromMemory(platform: platform, language: language) {
            application.nStackConfig.log("Memory cache used")
            return memoryTranslate
        }
        
        // Try drop cache
        if let cacheTranslate = freshFromCache(platform: platform, language: language) {
            application.nStackConfig.log("Drop cache used")
            return cacheTranslate
        }
        
        // Fetch from API
        do {
            application.nStackConfig.log("Fetching from API")
            let apiTranslate = try application.connectionManager.getTranslation(application: application, platform: platform, language: language)
            application.nStackConfig.log("Fetched from API success")
            
            // Set cache
            setCache(translate: apiTranslate)
            
            // Remove failed attempt
            attempts.removeValue(forKey: cacheKey)
            
            return apiTranslate
            
        } catch {
            attempts[Translate.cacheKey(platform: platform, language: language)] = try TranslationAttempt(error: error)
            
            throw error
        }
    }
    
    private final func freshFromMemory(platform: String, language: String) -> Translation?
    {
        let cacheKey = Translate.cacheKey(platform: platform, language: language)
        
        // Look up in memory
        guard let translation: Translation = translations[cacheKey] else {
            return nil
        }
        
        // If outdated remove
        if translation.isOutdated() {
            
            translations.removeValue(forKey: cacheKey)
            return nil
        }
        
        return translation
    }
    
    private final func freshFromCache(platform: String, language: String) -> Translation?
    {
        let cacheKey = Translate.cacheKey(platform: platform, language: language)
        do {
            guard let translateNode: Node = try assertCache().get(cacheKey) else {
                return nil
            }

            let translate = try Translation(translateConfig: config, application: application, node: translateNode)

            if(translate.isOutdated()) {
                application.nStackConfig.log("Droplet cache is outdated removing it")
                try assertCache().delete(cacheKey)
                return nil
            }
            
            return translate
        } catch {
            application.nStackConfig.log("NStack.Translate.freshFromCache error: " + error.localizedDescription)
            return nil
        }
    }
    
    private final func setCache(translate: Translation) {
        do  {
            let cacheKey = Translate.cacheKey(platform: translate.platform, language: translate.language)
            
            application.nStackConfig.log("Caching translate on key: \(cacheKey)")
            
            // Put in memoery cache
            translations[cacheKey] = translate
            
            // Put in drop cache
            try assertCache().set(cacheKey, translate.toNode())
        } catch {
            application.nStackConfig.log(error.localizedDescription)
        }
    }
    
    private static func cacheKey(platform: String, language: String) -> String {
        
        return platform.lowercased() + "_" + language.lowercased()
    }
}
