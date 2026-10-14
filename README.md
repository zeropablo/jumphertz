# Jumphertz

**Jumphertz — clean Focusrite Scarlett mic in Discord on macOS**

**Version 1.0** — testée uniquement sur une Scarlett 16i16 4th Gen (Mac Mini M4, macOS 26). Tes retours sont les bienvenus, surtout sur d'autres modèles (Solo, 2i2, 4i4…) et sur Mac Intel : ouvre une [issue](https://github.com/zeropablo/jumphertz/issues).

**Version 1.0** — tested only on a Scarlett 16i16 4th Gen (Mac Mini M4, macOS 26). Feedback is very welcome, especially on other models (Solo, 2i2, 4i4…) and Intel Macs: open an [issue](https://github.com/zeropablo/jumphertz/issues).

Youtube Tuto: https://www.youtube.com/watch?v=2-ouzThCcSY

[Français](#français) · [English](#english)

---

## Français

Jumphertz permet d'utiliser une **Focusrite Scarlett dans Discord sur macOS**, sans voix hachée ni robotique. Il tourne en arrière-plan et ne travaille que lorsque Discord est ouvert.

Il ne modifie pas Discord et n'interagit pas avec lui : il alimente un micro virtuel au niveau de macOS (BlackHole 2ch), que Discord utilise comme n'importe quel micro. Aucun risque pour ton compte.

Développé avec l'aide de Claude (Anthropic).

### Prérequis

macOS 13 ou plus récent, une Scarlett (tout modèle), l'app Discord et [Homebrew](https://brew.sh).

### Installation

Dans **Terminal**, colle chaque bloc et appuie sur Entrée.

**1.** Outils d'Apple (une fenêtre s'ouvre si besoin : clique sur **Installer**) :
```
xcode-select --install
```

**2.** BlackHole (ton mot de passe Mac est demandé), puis **redémarre ton Mac** :
```
brew install blackhole-2ch
```

**3.** Jumphertz (la compilation prend une à deux minutes), puis clique sur **Autoriser** quand macOS demande l'accès au micro :
```
git clone --branch v1.0.0 https://github.com/zeropablo/jumphertz.git ~/jumphertz
cd ~/jumphertz && scripts/install.sh
```

**4.** Rends la commande `jumphertz` disponible dans Terminal (une seule fois) :
```
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### ⚠️ Étape la plus importante : Discord

> [!IMPORTANT]
> Dans Discord, le périphérique d'entrée doit être **BlackHole 2ch**, PAS ta Scarlett. C'est par BlackHole que Jumphertz envoie ta voix à Discord. Sans ce réglage, rien ne marche.

**5.** Dans Discord, **Paramètres** › **Voix et vidéo** :
- **Périphérique d'entrée** : **BlackHole 2ch**
- **Suppression du bruit** : Aucune

C'est fini. Jumphertz démarre seul à chaque session.

### Commandes

| Commande | Effet |
|---|---|
| `jumphertz --status` | Vérifier que tout marche |
| `jumphertz --set-channel 2` | Micro branché sur l'entrée 2 |
| `jumphertz --set-gain -6` | Baisser le volume (en dB) |
| `jumphertz --reset-config` | Réglages par défaut |

Toutes les commandes : `jumphertz --help`.

### Un problème ?

**Première chose à vérifier : l'entrée Discord est-elle sur BlackHole 2ch ?**

Lance `jumphertz --diagnose` et joins le fichier créé sur ton Bureau à une [issue](https://github.com/zeropablo/jumphertz/issues). Ton nom d'utilisateur et les numéros de série y sont masqués ; ouvre-le pour vérifier avant de l'envoyer. Pour tester Jumphertz sur ta configuration : [TESTING.md](TESTING.md). Questions fréquentes et dépannage : [docs/troubleshooting.md](docs/troubleshooting.md).

### Désinstaller

```
cd ~/jumphertz && scripts/uninstall.sh
```

Puis, si tu veux, supprime le dossier `~/jumphertz` et BlackHole (`brew uninstall blackhole-2ch`).

---

## English

Jumphertz lets you use a **Focusrite Scarlett in Discord on macOS**, without choppy or robotic voice. It runs in the background and only works while Discord is open.

It doesn't modify Discord or interact with it: it feeds a virtual microphone at the macOS level (BlackHole 2ch), which Discord uses like any other microphone. No risk for your account.

Built with the help of Claude (Anthropic).

### Requirements

macOS 13 or later, a Scarlett (any model), the Discord app and [Homebrew](https://brew.sh).

### Install

In **Terminal**, paste each block and press Enter.

**1.** Apple tools (a window opens if needed: click **Install**):
```
xcode-select --install
```

**2.** BlackHole (your Mac password is requested), then **restart your Mac**:
```
brew install blackhole-2ch
```

**3.** Jumphertz (building takes a minute or two), then click **Allow** when macOS asks for microphone access:
```
git clone --branch v1.0.0 https://github.com/zeropablo/jumphertz.git ~/jumphertz
cd ~/jumphertz && scripts/install.sh
```

**4.** Make the `jumphertz` command available in Terminal (once):
```
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### ⚠️ Most important step: Discord

> [!IMPORTANT]
> In Discord, the input device must be **BlackHole 2ch**, NOT your Scarlett. BlackHole is how Jumphertz sends your voice to Discord. Without this setting, nothing works.

**5.** In Discord, **Settings** › **Voice & Video**:
- **Input Device**: **BlackHole 2ch**
- **Noise Suppression**: None

Done. Jumphertz starts on its own at every login.

### Commands

| Command | Effect |
|---|---|
| `jumphertz --status` | Check that everything works |
| `jumphertz --set-channel 2` | Mic plugged into input 2 |
| `jumphertz --set-gain -6` | Lower the volume (in dB) |
| `jumphertz --reset-config` | Default settings |

All commands: `jumphertz --help`.

### Something wrong?

**First thing to check: is Discord's input set to BlackHole 2ch?**

Run `jumphertz --diagnose` and attach the file created on your Desktop to an [issue](https://github.com/zeropablo/jumphertz/issues). Your user name and serial numbers are masked in it; open it to check before sending. To test Jumphertz on your setup: [TESTING.md](TESTING.md). FAQ and troubleshooting: [docs/troubleshooting.md](docs/troubleshooting.md).

### Uninstall

```
cd ~/jumphertz && scripts/uninstall.sh
```

Then, if you like, delete the `~/jumphertz` folder and BlackHole (`brew uninstall blackhole-2ch`).

---

Made by **zeropablo** with AI assistance (Claude Code). [MIT license](LICENSE). Uses [libsamplerate](https://github.com/libsndfile/libsamplerate) (BSD-2, see [ThirdPartyNotices](Resources/ThirdPartyNotices)) and [BlackHole](https://github.com/ExistentialAudio/BlackHole) (installed separately, not distributed with Jumphertz). Not affiliated with Discord or Focusrite. Developers: [docs/development.md](docs/development.md).
