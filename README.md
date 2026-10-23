# Colors

**Colors** è un'app per iPhone di **color grading e montaggio video**, ispirata al flusso di lavoro dei programmi professionali (pagine Media, Edit, Color, Deliver). Si usa in due modi:

- **Modalità telefono:** tutta l'app sullo schermo dell'iPhone, con i comandi touch.
- **Modalità monitor / AirPlay:** colleghi l'iPhone a un monitor (cavo USB‑C/HDMI) o a una TV/Mac con AirPlay. Sul monitor compare un'interfaccia completa "da computer", mentre il telefono diventa **trackpad e tastiera**. Funziona anche con un mouse vero collegato a un hub USB.

Tutto funziona sul telefono, senza internet e senza librerie esterne: solo framework Apple (SwiftUI, Core Image, AVFoundation, Vision, Photos).

---

## Cosa può fare

### Pagina Media
- Importa foto e video dalla **Libreria Foto**.
- Importa dai **File**, da cartelle e da **chiavette USB** collegate (cartelle collegate con accesso permanente).
- Riconosce il **codec** di ogni file (H.264, HEVC, ProRes…) e avvisa se un formato non è supportato (es. Blackmagic RAW).
- **Media Pool**: i media importati restano nel progetto, pronti da trascinare nella timeline.
- **Progetti**: crea, apri, rinomina ed elimina progetti.

### Pagina Edit (montaggio)
- **Timeline** con clip video, foto e traccia musica, con forma d'onda dell'audio.
- **Lama** per tagliare le clip nel punto esatto (con linea di taglio sotto il puntatore), a qualsiasi zoom.
- **Rifilo** trascinando l'inizio o la fine della clip (resta uno spazio vuoto, come nei programmi professionali), **Rifila alla testina**, chiusura degli spazi.
- Trascinamento dei media dal Media Pool alla timeline.
- **Musica**: aggiungi brani da Musica/File/cartelle, taglio, volume e dissolvenze.
- **Inspector**: velocità, volume, inquadratura (zoom, posizione, rotazione, specchio), transizioni, titoli.
- Stabilizzazione (anche modalità "treppiede"), reframe automatico sul soggetto, sottotitoli automatici dal parlato, divisione automatica per cambi di scena.

### Pagina Color
- **Nodi** in serie con anteprima, attivazione/disattivazione, nome.
- **Primarie**: ruote Lift / Gamma / Gain / Offset (o barre), Temperatura, Tint, Contrasto, Pivot, Mid/Detail, Esposizione, Color Boost, Ombre, Luci, Saturazione, Hue, Lum Mix, bilanciamento automatico e **contagocce** per il punto di bianco.
- **HDR**: ruote per zone (Black, Dark, Shadow, Light, Highlight, Specular) con esposizione, saturazione e ampiezza, più i controlli globali.
- **Curve** (Y/R/G/B, Hue vs Hue, Hue vs Sat, Hue vs Lum, Lum vs Sat, Sat vs Sat, Sat vs Lum).
- **Warper** a griglia sul vettorscopio, con i colori presi dal video.
- **Qualificatore** (HSL), **Finestre/maschere** (cerchio, lineare…) spostabili direttamente sul video, con **tracker**.
- **Mixer RGB**, **Effetti** (nitidezza, grana, glow, halation, riduzione rumore, sfocatura), **Color Space Transform** (camere Log → Rec.709), **LUT .cube** e **CDL**.
- **Galleria** di still per confronto.
- **Scope**: Parade, Waveform, Vettorscopio, Istogramma, CIE 1931.
- **Keyframe** per animare la correzione.
- Funzioni "AI" sul telefono: auto colore, look descritto a parole (Apple Intelligence).
- Annulla / Ripeti.

### Pagina Deliver (esportazione)
- Preset di esportazione (anche per i social), risoluzione, formato, ProRes 422 HQ 10 bit o H.264/HEVC.
- **Coda di render**: aggiungi più lavori e avviali insieme.
- Salvataggio nel **Rullino** o in una **cartella collegata / chiavetta USB**.

---

## Modalità monitor / AirPlay

Quando l'iPhone è collegato a un monitor o in AirPlay:

| Monitor | iPhone |
|---|---|
| Interfaccia completa con barra dei menu (File, Modifica, Clip, Nodi, Vista, Riproduzione, Area di lavoro), pannelli, viewer, timeline, scope | Trackpad a tutto schermo + tastiera |

- **Puntatore** sul monitor mosso dal trackpad del telefono o da un **mouse** collegato (tasto sinistro, destro e rotellina).
- **Tasto destro** apre i menu contestuali (nodi, clip, progetti…), la **rotellina** scorre liste e timeline.
- Le finestre di sistema (scelta dei file e delle cartelle) e le finestre di testo (es. rinomina) compaiono **sul monitor**.
- Video a **schermo intero** sul monitor.
- Se non c'è una tastiera fisica, si usa quella del telefono; con una tastiera collegata si scrive direttamente.
- All'avvio con il monitor collegato appare la finestra **Continua progetto / Nuovo progetto**.

> Nota tecnica: per avere una vera seconda schermata (e non il semplice mirroring) l'app usa una scena "companion" per display esterno di UIKit (iOS 26+). Il mouse con il tasto sinistro richiede AssistiveTouch attivo.

---

## Requisiti

- iPhone con **iOS 18** o più recente (la modalità monitor separata richiede iOS 26).
- Per compilare: Mac con **Xcode 16** o più recente e un Apple ID (anche gratuito).

## Come compilare

1. Apri `Colorista.xcodeproj` con Xcode.
2. Target **Colorista** → *Signing & Capabilities*: spunta *Automatically manage signing* e scegli il tuo Team.
   Se il Bundle Identifier è già in uso, cambialo (es. `com.tuonome.Colors`).
3. Collega l'iPhone, sceglilo come destinazione e premi **Play** (⌘R).
4. Sull'iPhone: *Impostazioni › Generali › VPN e gestione dispositivi* → autorizza il tuo account, e attiva la *Modalità sviluppatore*.

Altre cartelle:
- `Alternativa XcodeGen/` — `project.yml` per rigenerare il progetto con XcodeGen.
- `Versione xtool (Windows)/` — lo stesso codice nel formato per compilare da Windows/Linux con [xtool](https://github.com/xtool-org/xtool).

## Struttura del codice

| File | Contenuto |
|---|---|
| `ColoristaApp.swift`, `ContentView.swift`, `Pagine.swift` | App e pagine sul telefono |
| `Studio.swift`, `Progetto.swift`, `Sequenza.swift` | Stato dell'app, progetti, timeline e riproduzione |
| `Grade.swift`, `ColorScience.swift`, `Nodi.swift`, `GrafoNodi.swift` | Motore di correzione colore e nodi |
| `Palette.swift`, `ColorWheel.swift`, `CurveEditor.swift`, `TipoCurva.swift` | Palette della pagina Color |
| `SchermoEsterno.swift`, `Trackpad.swift` | Interfaccia sul monitor, trackpad, mouse e tastiera |
| `Cartelle.swift` | Cartelle collegate, chiavette USB, riconoscimento codec |
| `Render.swift`, `Esportazione.swift`, `FormatoSocial.swift`, `Inspector.swift` | Esportazione, coda di render, Inspector |
| `Scope.swift`, `Tracker.swift`, `Stabilizzatore.swift`, `Reframe.swift`, `Sottotitoli.swift`, `CambiScena.swift` | Scope e analisi video |
| `CubeLUT.swift`, `CDL.swift`, `AI.swift`, `LookAParole.swift`, `PannelloAI.swift` | LUT, CDL e funzioni intelligenti |

## Note

Colors è un progetto indipendente. L'interfaccia si ispira all'organizzazione dei programmi di color grading professionali, ma tutto il codice è scritto da zero. DaVinci Resolve è un marchio di Blackmagic Design; questo progetto non è affiliato né approvato da Blackmagic Design.
