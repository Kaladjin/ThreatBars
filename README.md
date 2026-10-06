# 🛡️ ThreatBars

Threat meter pour **World of Warcraft: Forever**, au look du damage meter intégré de Blizzard.

Il affiche la menace de chaque membre du groupe sur ta cible. Les chiffres sont **calculés par le serveur** (`UnitDetailedThreatSituation`) : ils sont exacts, pas estimés. Le combat log étant interdit aux addons sur Forever, c'est la seule source fiable.

## 📥 Installation

1. Va dans [**Releases**](../../releases/latest) et télécharge `ThreatBars-vX.Y.Z.zip`.
2. Dézippe-le dans `World of Warcraft\_classic_beta_\Interface\AddOns\` : tu dois obtenir un dossier `ThreatBars` contenant `ThreatBars.toc`.
3. **Redémarre complètement le jeu** (un `/reload` ne suffit pas pour un nouvel addon).

> ⚠️ Ne télécharge pas le bouton vert « Code → Download ZIP » : le dossier aurait le mauvais nom (`ThreatBars-main`) et l'addon ne se chargerait pas.

**Mise à jour** : remplace le dossier `ThreatBars` par celui de la nouvelle version. Tes réglages sont conservés.
Pour être prévenu des nouvelles versions : bouton **Watch → Custom → Releases** en haut de cette page.

## 📊 Lecture du meter

| Ligne | Affichage |
|---|---|
| Celui qui a l'aggro | menace (menace/seconde) + **100 %** en vert, ex. `125M (2.1M)  100%` |
| Les autres | menace (menace/seconde) + écart avec le tank, ex. `116M (1.9M)  -7%` |

- L'écart passe en **rouge** quand il devient positif : en mêlée, tu es à moins de 10 % de reprendre l'aggro.
- La menace par seconde est une moyenne depuis que le mob est suivi.
- Le chronomètre du combat s'affiche à gauche de l'en-tête.
- Cible un allié : le meter suit sa cible (pratique pour les heals).
- Quand un joueur ennemi (PvP) est proche, Blizzard masque les valeurs de menace aux addons : le meter passe alors en affichage simple (menace + % du tank en gris, sans écart ni alerte) et revient à la normale tout seul.

## 📜 Historique

Le bouton **Actuel** dans l'en-tête (à la même place que sur le meter Blizzard) ouvre la liste des **10 dernières rencontres** : nom du mob, durée et heure. En choisir une affiche l'état figé en fin de combat. Au prochain combat, le meter revient automatiquement sur « Actuel ».

Une rencontre = un combat. Si tu as ciblé plusieurs mobs, c'est celui suivi le plus longtemps qui est gardé (les autres sont comptés en `+N`). Seuls les mobs que tu as ciblés sont suivis.

## 🔔 Alerte

Son + voile rouge quand un DPS approche du pull (90 % par défaut).
Si tu es DPS, l'alerte se déclenche quand c'est toi qui approches.

## ⚙️ Options

Roue crantée dans l'en-tête du meter, ou `/tb`.

- Activer/couper l'alerte, seuil (50–130 % du pull), volume du son
- Afficher seulement en combat
- Opacité du fond et opacité générale
- Verrouiller la position, aperçu avec barres factices
- Effacer l'historique

Déplacer : glisser l'en-tête. Redimensionner : coin bas-droit.

## ⌨️ Commandes

| Commande | Effet |
|---|---|
| `/tb` | ouvre les options |
| `/tb test` | aperçu avec barres factices |
| `/tb lock` / `/tb unlock` | verrouille / déverrouille |
| `/tb warn 85` | seuil d'alerte en % du pull |
| `/tb volume 50` | volume de l'alerte |
| `/tb show` / `/tb hide` | affiche / masque |
| `/tb reset` | réglages par défaut |
| `/tb clearlog` | efface l'historique |
| `/tb probe` | diagnostic (à lancer en combat pour un rapport de bug) |

## 🐛 Signaler un bug

Ouvre une [Issue](../../issues) avec : ce qui s'est passé, ta version de ThreatBars, et si possible la sortie de `/tb probe` en combat.

## 📜 Licence

[GPL-3.0-or-later](LICENSE) : libre d'utiliser, modifier et redistribuer, à condition de partager les modifications sous la même licence.
