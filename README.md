# KidSafe

Contrôle parental pour macOS basé sur Privoxy : une app dans la barre de menus, en français et en anglais.

| Cible | Rôle |
|---|---|
| `KidSafeCore` | Lecture des listes, génération des fichiers Privoxy, installation avec test et retour arrière, catalogue, traductions |
| `KidSafeApp` (produit `KidSafe`) | App SwiftUI de la barre de menus et fenêtre de réglages |
| `kidsafe-blocklist` | CLI, qui remplace `privoxy-blocklist.sh` et `blocklist2privoxy.sh` |

L'app et la CLI partagent le même catalogue : `~/Library/Application Support/KidSafe/catalog.json`.

## Construire et lancer

```sh
scripts/test.sh                      # tests (fonctionne avec les seuls Command Line Tools)
scripts/build-app.sh                 # build/KidSafe.app pour ce Mac
scripts/build-app.sh --universal     # Apple Silicon + Intel
swift scripts/make-icon.swift Resources/AppIcon.png   # redessine l'icône (puis iconutil, voir l'historique git)
open build/KidSafe.app
```

Pour essayer : `brew install privoxy`, ouvrir l'app, puis cliquer sur « Configurer ».

**Le Mac ne doit jamais perdre sa connexion** :
- au lancement, KidSafe démarre Privoxy (service launchd s'il existe, sinon processus de l'app), puis remet
  le proxy si le parent l'avait activé ;
- en quittant, KidSafe retire d'abord le proxy, puis arrête Privoxy. Si le proxy ne peut pas être retiré,
  Privoxy reste allumé ;
- toutes les 5 s, si le proxy pointe vers un Privoxy qui ne répond plus, KidSafe le relance ; s'il ne repart pas,
  le proxy est retiré (puis remis quand Privoxy revient) ;
- seul le proxy 127.0.0.1:<port de Privoxy> est retiré : un proxy configuré par ailleurs n'est jamais touché ;
- Réglages → Général → « Désinstaller KidSafe… » remet le Mac dans son état d'origine.

Développement : les variables `KIDSAFE_SUPPORT_DIR` et `KIDSAFE_PRIVOXY_CONF` isolent l'app de la vraie configuration.

## L'app

- **Barre de menus** : état de la protection, interrupteur **Filtrage** (pause sans rien supprimer),
  résumé (catégories, réseaux sociaux bloqués en ce moment, domaines perso), « Mettre à jour les listes »,
  « Réglages… », « Soutenir KidSafe » (si un lien est configuré), « Rechercher des mises à jour », « Quitter ».
- **Réglages** :
  - **Listes** : catégories et listes ajoutées (listes gratuites, adresse web, fichier du Mac) ;
  - **Réseaux sociaux** : Facebook, Instagram, TikTok, X, Snapchat, YouTube, Threads, WhatsApp, Telegram,
    Discord, Reddit, Twitch, Pinterest, BeReal. Chacun peut être autorisé, toujours bloqué, bloqué pendant
    des plages, ou autorisé seulement pendant des plages (jours de la semaine + heures, plages de nuit acceptées) ;
  - **Domaines** : domaines bloqués à la main et liste blanche (un domaine ne peut pas être dans les deux) ;
  - **Général** : filtrage, mode strict, fréquence de mise à jour des listes (jamais → chaque semaine),
    mot de passe parent, Privoxy et proxy, langue, don.
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
B=build/KidSafe.app/Contents/MacOS/kidsafe-blocklist
$B lists
$B enable gambling
$B enable adult-ut1 --yes                       # liste lourde : avertissement sans --yes
$B library
$B add-list --from-library easylist
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

## À faire

- Helper root (LaunchDaemon installé par le .pkg) protégé par un mot de passe parent. Le catalogue passera
  alors dans `/Library/Application Support/KidSafe`, où l'enfant ne peut rien modifier.
- .pkg contenant Privoxy compilé (sources GPL fournies), puis signature et notarisation (compte Apple Developer).
- Recherche de nouvelles versions de l'app avec Sparkle.
- Plages horaires, journal des sites bloqués, page de blocage locale.
- Protections contre le contournement : compte enfant standard, profil qui verrouille le proxy, mot de passe parent.

## Publier une version de test

```sh
scripts/make-dmg.sh        # build/KidSafe.dmg : app universelle + raccourci Applications + mode d'emploi
```

Joindre `build/KidSafe.dmg` à une Release GitHub. Le nom du fichier ne change pas, donc ce lien pointe
toujours vers la dernière version : https://github.com/lls-hcr/kidsafe/releases/latest/download/KidSafe.dmg

L'adresse e-mail de « Envoyer un avis… » se règle dans `scripts/local.env` (`KIDSAFE_FEEDBACK_EMAIL=…`),
un fichier ignoré par git : elle n'apparaît pas dans le dépôt public.

## Licence

KidSafe est distribué sous licence GNU GPL v3 (voir `LICENSE`). Privoxy est sous GPL v2 ou ultérieure ;
les listes de blocage gardent leur propre licence (indiquée dans le catalogue).

Soutenir le projet : https://github.com/sponsors/lls-hcr · Page du projet : https://mizuki.ch/documentation/kidsafe/
