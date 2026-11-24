import Foundation

/// Session HTTP des téléchargements de KidSafe lui-même : listes, recherche et téléchargement des mises à jour.
///
/// Elle ne passe pas par le proxy du système, c'est-à-dire par le Privoxy de KidSafe. Sinon le filtrage
/// pourrait bloquer KidSafe lui-même :
/// - mode strict : tout est bloqué sauf la liste blanche (listes et mises à jour introuvables) ;
/// - règles génériques de Privoxy : « ad*. » bloque adguardteam.github.io (AdGuard DNS filter) ;
/// - l'hôte d'une liste bloqué par une autre liste.
/// Privoxy n'a pas de proxy amont (pas de ligne `forward`) : il se connecte lui-même en direct,
/// KidSafe fait de même. Les certificats TLS restent vérifiés.
enum KidSafeHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]   // dictionnaire vide : aucun proxy (nil = réglages du système)
        return URLSession(configuration: config)
    }()
}
