# Changelog

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
