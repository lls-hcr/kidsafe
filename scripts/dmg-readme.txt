KidSafe — contrôle parental pour Mac (version de test)
=====================================================

1. Glissez KidSafe dans le dossier Applications.
2. Ouvrez KidSafe. macOS indique qu'il ne peut pas vérifier l'app (elle n'est pas
   encore signée par Apple) : allez dans Réglages Système → Confidentialité et
   sécurité, puis cliquez sur « Ouvrir quand même ».
3. Cette version de test a besoin de Privoxy, installé avec Homebrew (https://brew.sh) :
       brew install privoxy
       brew services start privoxy
   La version finale installera Privoxy elle-même.
4. Cliquez sur le bouclier dans la barre de menus, puis sur « Configurer » pour
   faire passer le Mac par le filtre.

Guide complet : https://mizuki.ch/documentation/kidsafe/
Avis et problèmes : menu du bouclier → « Envoyer un avis… »


KidSafe — parental control for Mac (test version)
================================================

1. Drag KidSafe to the Applications folder.
2. Open KidSafe. macOS says it can't verify the app (it isn't signed by Apple yet):
   go to System Settings → Privacy & Security and click “Open Anyway”.
3. This test version needs Privoxy, installed with Homebrew (https://brew.sh):
       brew install privoxy
       brew services start privoxy
   The final version will install Privoxy itself.
4. Click the shield in the menu bar, then “Set up” to route the Mac through the filter.

Full guide: https://mizuki.ch/documentation/kidsafe/
Feedback and issues: shield menu → “Send Feedback…”
