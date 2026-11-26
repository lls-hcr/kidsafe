# Yamoxy

*Anciennement KidSafe.* Yamoxy réunit *yamori* (家守), le gardien de la maison en japonais (c'est aussi le nom du gecko), et *proxy*, le relais par lequel passe la navigation.

*[English](README.md)*

Contrôle parental pour macOS basé sur Privoxy : une app dans la barre de menus, en français et en anglais.

| Cible | Rôle |
|---|---|
| `KidSafeCore` | Lecture des listes, génération des fichiers Privoxy, installation avec test et retour arrière, catalogue, traductions |
| `KidSafeApp` (produit `Yamoxy`) | App SwiftUI de la barre de menus et fenêtre de réglages |
| `kidsafe-blocklist` (produit `yamoxy-blocklist`) | CLI, qui remplace `privoxy-blocklist.sh` et `blocklist2privoxy.sh` |

L'app et la CLI partagent le même catalogue : `~/Library/Application Support/Yamoxy/catalog.json`.

## Installer et désinstaller (utilisateurs)

Tout se fait depuis [`Yamoxy.dmg`](https://github.com/lls-hcr/yamoxy/releases/latest/download/Yamoxy.dmg), Privoxy est intégré :

1. Glissez **Yamoxy** dans **Applications** et ouvrez-le. macOS demande de confirmer l'ouverture d'une app
   téléchargée : cliquez sur **Ouvrir**. Yamoxy est signé (Developer ID) et notarisé par Apple.
2. C'est tout : au premier lancement, Yamoxy active la protection tout seul (gecko dans la barre de
   menus). Sur un compte standard, macOS demande une fois le mot de passe administrateur.
3. Mises à jour : Yamoxy cherche les nouvelles versions chaque semaine (ou via « Rechercher des mises à jour… »)
   et peut s'installer tout seul : téléchargement, vérification de l'empreinte SHA-256 publiée par GitHub,
   puis remplacement et relance. Les réglages sont conservés.
4. Pour tout enlever : double-cliquez sur **Désinstaller Yamoxy** dans le `.dmg` (ou Réglages → Général →
   « Désinstaller Yamoxy… »). Le mot de passe parent est demandé s'il existe.

Avec Homebrew : `brew tap lls-hcr/tap && brew trust lls-hcr/tap && brew install --cask yamoxy`.

## Construire et lancer

```sh
scripts/test.sh                      # tests (fonctionne avec les seuls Command Line Tools)
scripts/build-app.sh                 # build/Yamoxy.app pour ce Mac
scripts/build-app.sh --universal     # Apple Silicon + Intel
cat Sources/KidSafeApp/GeckoShape.swift scripts/make-icon.swift | swift - Resources/AppIcon.png   # redessine l'icône (puis iconutil, voir l'historique git)
open build/Yamoxy.app
```

Privoxy intégré : `scripts/build-privoxy.sh` compile Privoxy 4.2.0 et PCRE2 depuis leurs sources (universel,
`brew install autoconf` nécessaire sur la machine de construction). L'app l'installe dans
`~/Library/Application Support/Yamoxy/privoxy/` et l'écoute se fait sur `127.0.0.1:8128`, un port dédié.

**Le Mac ne doit jamais perdre sa connexion** :
- au lancement, Yamoxy démarre son Privoxy intégré, puis remet
  le proxy si le parent l'avait activé ;
- en quittant, Yamoxy retire d'abord le proxy, puis laisse Privoxy en simple relais (`toggle 0`, rien n'est
  bloqué) jusqu'à la fin de la session : les apps qui ont mémorisé l'adresse du proxy à leur lancement gardent
  internet. Yamoxy le reprend au lancement suivant ; le désinstalleur l'arrête. Si le proxy ne peut pas être
  retiré, Privoxy reste allumé et filtre ;
- toutes les 5 s, si le proxy pointe vers un Privoxy qui ne répond plus, Yamoxy le relance ; s'il ne repart pas,
  le proxy est retiré (puis remis quand Privoxy revient), sauf si le parent a choisi de couper internet quand Yamoxy ne filtre pas ;
- seul le proxy 127.0.0.1:<port de Privoxy> est retiré : un proxy configuré par ailleurs n'est jamais touché ;
- Réglages → Général → « Désinstaller Yamoxy… » remet le Mac dans son état d'origine.

Développement : les variables `KIDSAFE_SUPPORT_DIR` et `KIDSAFE_PRIVOXY_CONF` isolent l'app de la vraie configuration.

## L'app

- **Message « site bloqué »** : Yamoxy affiche au centre de l'écran le site bloqué et la raison, quel que soit le navigateur ;
  il disparaît au premier clic (publicités et pistage bloqués en arrière-plan non signalés).
- **Protection contre les contournements** (avec un mot de passe parent) : couper internet quand Yamoxy est fermé
  sans le mot de passe (au lieu d'un accès sans filtre), verrouiller le proxy dans Firefox (règle officielle de Firefox,
  mot de passe administrateur), proposition de bloquer VPN et proxys, arrêts inattendus de Yamoxy signalés dans le moniteur.
  Le guide d'utilisation détaille les limites et les parades (section « Limites »).
- **Barre de menus** : état de la protection, interrupteur **Filtrage** (pause sans rien supprimer), **Désactivation temporaire** (30 s à 1 h, reprise automatique),
  résumé (catégories, réseaux sociaux bloqués en ce moment, domaines perso), « Mettre à jour les listes »,
  « Réglages… », « Soutenir Yamoxy » (si un lien est configuré), « Rechercher des mises à jour », « Quitter ».
- **Réglages** :
  - **Listes** : listes par thème (adultes : HaGeZi NSFW cochée par défaut, OISD NSFW, UT1 complète ; publicité et
    pistage : HaGeZi Pro, OISD Big ; arnaques et logiciels malveillants : HaGeZi Threat Intelligence Feeds ;
    contournement), niveau Léger / Normal / Renforcé pour HaGeZi Pro et Threat Intelligence Feeds, fiche ⓘ de chaque
    liste (auteur, fréquence de mise à jour, risque de blocage par erreur, licence) ; autres thèmes (jeux d'argent,
    violence, drogues, rencontres…) et autres listes gratuites dans le menu « Ajouter une liste », ainsi qu'une
    adresse web ou un fichier du Mac ;
  - **Réseaux sociaux** : Facebook, Instagram, TikTok, X, Snapchat, YouTube, Threads, WhatsApp, Telegram,
    Discord, Reddit, Twitch, Pinterest, BeReal. Chacun peut être autorisé, toujours bloqué, bloqué pendant
    des plages, ou autorisé seulement pendant des plages (jours de la semaine + heures, plages de nuit acceptées) ;
  - **Domaines** : domaines bloqués à la main et liste blanche (un domaine ne peut pas être dans les deux) ;
  - **Général** : filtrage, mode strict, fréquence de mise à jour des listes (jamais → chaque semaine),
    mot de passe parent, Privoxy et proxy, langue, don ;
  - bouton **Réglages par défaut…** dans les onglets Listes, Réseaux sociaux, Domaines et Général
    (le mot de passe et les protections restent).
- **Moniteur** (menu du gecko) : petite fenêtre flottante avec les compteurs en direct (requêtes filtrées,
  bloquées, pourcentage, domaines dans les listes, dernier blocage) et un **mode détaillé** : page HTML locale
  autonome avec tuiles, graphiques par heure et par jour, domaines les plus bloqués, blocages par catégorie et
  derniers blocages. Rien ne tourne quand la fenêtre est fermée.
- **Avancé** (mot de passe parent, avec mise en garde) : port de Privoxy (choisi automatiquement s'il est occupé,
  ou réglé à la main), éditeur de Privoxy dans le navigateur (`http://p.p`, refermé tout seul après une heure),
  règles personnelles (`user.action`, vérifiées avant d'être appliquées), journal des sites bloqués, domaines qui
  ne passent pas par le filtre, état, redémarrage et réinitialisation de Privoxy. Filtrer d'autres appareils : à venir.
- **Mot de passe parent** (facultatif) : demandé pour toute modification, la pause et « Quitter » ;
  il reste déverrouillé 5 minutes. Seule son empreinte PBKDF2-SHA256 est enregistrée.
- Les plages horaires sont appliquées par l'app (vérification toutes les 30 s) : elle doit rester ouverte
  tant que le helper système n'existe pas.

Lien de don : GitHub Sponsors (https://github.com/sponsors/lls-hcr) par défaut ; `KIDSAFE_DONATE_URL=https://… scripts/build-app.sh` le remplace, `KIDSAFE_DONATE_URL=` (vide) masque le bouton. `.github/FUNDING.yml` affichera le bouton « Sponsor » sur GitHub.

## Traductions

`Sources/KidSafeCore/Resources/{fr,en}.lproj/Localizable.strings`. Les deux fichiers doivent avoir les mêmes clés.
La CLI suit la langue du système ; `KIDSAFE_LANG=en` la force.

## CLI

```sh
B=build/Yamoxy.app/Contents/MacOS/yamoxy-blocklist
$B lists
$B enable ads
$B level security normal                        # light | normal | strong
$B enable adult-ut1 --yes                       # liste lourde : avertissement sans --yes
$B library
$B add-list --from-library gambling
$B add-list --name "Ma liste" --url https://exemple.org/liste.txt
$B add-list --file ~/Documents/ma-liste.txt     # depuis le disque
$B remove-list ma-liste
$B block roblox.com | allow exemple.org
$B pause | resume                               # demande le mot de passe parent s'il existe
$B update [--dry-run] [--remove-legacy]         # télécharge, installe, teste, revient en arrière si erreur
$B uninstall
```

## Mesures (Mac Apple Silicon, Privoxy 4.2.0, 20/11/2026)

| Listes chargées | Domaines | Mémoire Privoxy | Temps de requête | Rechargement |
|---|---|---|---|---|
| HaGeZi NSFW + UT1 gambling | ~180 000 | 41 Mo | ~36 ms (comme sans liste) | instantané |
| UT1 adult complète | 4,6 M | 786 Mo | +~70 ms | ~4 s |
| HaGeZi TIF, niveau Normal (24/11/2026) | 345 000 | 53 Mo | +~3 ms | ~0,3 s |
| OISD NSFW (24/11/2026) | 498 000 | 74 Mo | +~3 ms | ~0,3 s |
| HaGeZi TIF, niveau Renforcé (24/11/2026) | 2,17 M | 315 Mo | +~19 ms | ~1,5 s |

## À faire

- Helper root (LaunchDaemon installé par le .pkg) protégé par un mot de passe parent. Le catalogue passera
  alors dans `/Library/Application Support/Yamoxy`, où l'enfant ne peut rien modifier.
- Journal des sites bloqués, page de blocage locale.
- Protections contre le contournement : compte enfant standard, profil qui verrouille le proxy, mot de passe parent.

## Publier une version de test

```sh
scripts/make-dmg.sh        # build/Yamoxy.dmg : app universelle + raccourci Applications + mode d'emploi
                           # signé et notarisé si un certificat « Developer ID Application » et le profil
                           # notarytool « kidsafe-notary » sont dans le trousseau ; ad hoc sinon
```

Joindre `build/Yamoxy.dmg` à une Release GitHub. Le nom du fichier ne change pas, donc ce lien pointe
toujours vers la dernière version : https://github.com/lls-hcr/yamoxy/releases/latest/download/Yamoxy.dmg

L'adresse e-mail de « Envoyer un avis… » se règle dans `scripts/local.env` (`KIDSAFE_FEEDBACK_EMAIL=…`),
un fichier ignoré par git : elle n'apparaît pas dans le dépôt public.

## Licence

Yamoxy est distribué sous licence GNU GPL v3 (voir `LICENSE`). Privoxy est sous GPL v2 ou ultérieure ;
les listes de blocage gardent leur propre licence (indiquée dans le catalogue).

Soutenir le projet : https://github.com/sponsors/lls-hcr · Page du projet : https://mizuki.ch/documentation/yamoxy/
