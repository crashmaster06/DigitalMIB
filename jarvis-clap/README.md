# Jarvis - double clap => reveil du bureau

Script Python qui ecoute le micro par defaut et, sur un **double clap**, :

1. joue de la musique (un fichier local en fond, ou un lien Spotify),
2. ouvre une liste de sites (n8n, Gmail, autant que tu veux) dans une nouvelle
   fenetre Chrome,
3. dit une phrase de bienvenue via **ElevenLabs**.

Adapte pour Windows. Toutes les valeurs (musique, sites, phrase) sont
configurees dans `jarvis.py` / `.env` - rien de code en dur specifique a
quelqu'un d'autre.

## Installation

Depuis ce dossier (`jarvis-clap/`), dans un terminal Windows :

```bat
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
```

Utilise toujours `.venv\Scripts\python` pour lancer le script (jamais juste
`python`), pour rester dans l'environnement virtuel du projet.

## Configuration (cle ElevenLabs)

1. Copie `.env.example` en `.env` (meme dossier que `jarvis.py`).
2. Va sur [elevenlabs.io](https://elevenlabs.io), cree un compte, recupere
   ta cle API (Profile > API Keys) et colle-la dans `ELEVENLABS_API_KEY`.
3. Choisis une voix dans **My Voices** (les voix "natives" de ton compte).
   Copie son Voice ID et colle-le dans `ELEVENLABS_VOICE_ID`.

**Important (plan gratuit) :** les voix de la *Voice Library* (bibliotheque
partagee) sont refusees par l'API sur le plan gratuit (erreur 402). Utilise
uniquement une voix de **My Voices** (voix par defaut de ton compte, ou une
voix clonee/creee par toi).

## Lancer

```bat
.venv\Scripts\python jarvis.py
```

Autorise l'acces au micro si Windows le demande. Arrete avec **Ctrl+C**.

## Musique sans ouvrir Spotify

Par defaut, le double clap ouvre le lien Spotify (`SONG_URI` dans `jarvis.py`),
ce qui lance l'appli Spotify ou un onglet de navigateur. Pour une musique
jouee en fond, sans ouvrir aucune fenetre :

1. Procure-toi une version **WAV** du son voulu (converti depuis un fichier
   que tu possedes, ou un son libre de droits).
2. Place-le dans le dossier `jarvis-clap` (ou ailleurs, avec un chemin complet).
3. Dans `.env`, ajoute : `SONG_FILE=wake.wav` (ou le chemin complet du fichier).

Si `SONG_FILE` est absent ou introuvable, le script revient automatiquement
au lien Spotify (`SONG_URI`).

## Ajouter des sites a ouvrir

Dans `.env`, ajoute une ligne `DASHBOARD_URLS` avec autant de sites que tu
veux, separes par des virgules :

```env
DASHBOARD_URLS=https://n8n.digital-mib.com/,https://mail.google.com/mail/u/0/#inbox,https://monsite.com
```

Tous s'ouvrent en onglets dans une meme nouvelle fenetre Chrome.

## Mode debug

Pour voir le niveau sonore et le seuil a chaque pic detecte (utile pour
regler la sensibilite) :

```bat
set JARVIS_DEBUG=1
.venv\Scripts\python jarvis.py
```

## Reglages (constantes en haut de `jarvis.py`)

| Constante | Effet |
| --- | --- |
| `SPIKE_RATIO` | Augmente si faux declenchements, baisse si les claps sont rates. |
| `MIN_RMS` | Plancher absolu de volume pour qu'un pic compte (evite les faux positifs en silence). |
| `CLAP_DECAY_WINDOW_S` / `CLAP_DECAY_RATIO` | Un vrai clap retombe vite : le niveau doit chuter sous `CLAP_DECAY_RATIO` du pic en moins de `CLAP_DECAY_WINDOW_S`. Une voix ou de la musique reste forte et est ignoree. |
| `MIN_DOUBLE_GAP_S` / `MAX_DOUBLE_GAP_S` | Ecart autorise entre les deux claps. |
| `COOLDOWN_S` | Temps minimum entre deux doubles claps confirmes. |
| `SAMPLE_RATE` | Essaie `48000` si `44100` ne fonctionne pas bien avec ton micro. |

## Depannage

- **Faux declenchements sur la voix/musique :** augmente `SPIKE_RATIO` ou
  `MIN_RMS`, ou resserre `CLAP_DECAY_RATIO` (ex: `0.30`).
- **Claps non detectes :** active `JARVIS_DEBUG=1`, regarde le niveau
  affiche pendant un clap et ajuste `MIN_RMS`/`SPIKE_RATIO` en consequence.
- **Mauvais micro :** au demarrage le script teste le micro par defaut ; s'il
  est silencieux, il choisit automatiquement le micro le plus actif. Pour en
  forcer un precis, mets `JARVIS_INPUT_DEVICE` dans `.env` (index ou bout de
  nom, liste avec `python -c "import sounddevice as sd; print(sd.query_devices())"`).
- **Pas de voix :** verifie `ELEVENLABS_API_KEY` / `ELEVENLABS_VOICE_ID` dans
  `.env`, et que la voix vient bien de *My Voices* (pas de la Voice Library
  sur un plan gratuit).
