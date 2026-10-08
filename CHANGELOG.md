# Changelog

## [0.5.1] - 2026-10-08
- **Détail de votre menace par capacité** (clic sur votre ligne, Maj+clic pour épingler), présenté comme le détail des dégâts du meter Blizzard : icône, menace totale, menace par seconde, % du total. Calculé après le combat.
- Méthode :
  - menace totale relevée sur **tous les mobs** du combat (cible + barres de vie ennemies) ;
  - dégâts et soins **exacts** par sort lus dans le meter Blizzard (coups blancs, DoT, procs, auras, Bouclier sacré, Épines, Consécration… compris) ;
  - sorts **sans dégâts** générant de la menace (Fracasser armure, cris, Provocation…) : liste fermée, menace mesurée directement après chaque lancer isolé. Un sort hors liste sans dégâts (Maîtrise du blocage…) ne reçoit jamais de menace ;
  - sorts à dégâts lancés (Frappe héroïque, Vengeance…) : menace mesurée directement quand c'est possible (bonus de menace compris), sinon part calculée sur leurs dégâts ;
  - le total affiché est toujours égal à la menace réelle.
- Commande `/tb rec` : sauvegarde les mesures brutes du dernier combat (pour affiner l'estimation).
- Les barres de vie ennemies (touche V) doivent être affichées pour la mesure multi-cibles.

## [0.4.0] - 2026-10-06
- **Menace par seconde** entre parenthèses à côté de la valeur, comme les DPS du meter Blizzard : `125M (2.1M)  100%`. Moyenne depuis que le mob est suivi.
- **Historique des 10 dernières rencontres** : sélecteur de session dans l'en-tête (même place que sur le meter Blizzard), « Actuel » ou une rencontre passée avec sa durée et son heure. L'état de fin de combat est figé (menace, TPS, écart).
- Chronomètre du combat dans l'en-tête.
- En combat, le meter revient automatiquement sur « Actuel ».
- Options : bouton « Effacer l'historique » ; commande `/tb clearlog`.
- Quand les valeurs sont secrètes, le % du tank s'affiche en gris (plus entre parenthèses, pour ne pas le confondre avec le TPS).

## [0.3.2] - 2026-10-04
- Correctif : erreur Lua « attempt to compare … secret string value » quand Blizzard rend les valeurs de menace secrètes (certains contenus). Le meter continue d'afficher la menace et le % du tank ; l'écart coloré et l'alerte restent indisponibles tant que les valeurs sont secrètes.

## [0.3.1] - 2026-10-04
- La menace s'affiche à l'échelle des autres threat meters (valeur brute du serveur, ×100 par rapport à avant).
- Celui qui a l'aggro affiche **100 %** en vert, en groupe comme en solo.

## [0.3.0] - 2026-10-04
- Fenêtre d'options (roue crantée dans l'en-tête, ou `/tb`) :
  - activer/couper l'alerte, seuil (50–130 % du pull), volume du son (0 % = voile seul), bouton « Tester le son » ;
  - afficher seulement en combat (reste 3 s après la fin du combat) ;
  - opacité du fond et opacité générale ;
  - verrouillage de la position, aperçu avec barres factices.

## [0.2.0] - 2026-10-03
- Interface calquée sur le damage meter intégré de Blizzard (mêmes textures, police, taille de barres).
- Chaque ligne : menace brute + écart en % avec le tank (rouge quand il devient positif).
- Alerte son + voile rouge dans le meter.

## [0.1.0] - 2026-10-03
- Première version.
