# Composer: statistiche di sessione al posto del selettore duplicato

Piano di implementazione per Luna · 13 settembre 2026 · base ispezionata: branch `dev`, working tree inizialmente pulito.

**Stato: scelta C compatta — implementata nel composer pubblico di `dev`; resta la validazione interattiva nell'app.** Le statistiche sono isolate per conversazione, persistite come metadati opzionali e alimentate dai campioni usage del runtime senza modificare la configurazione dei provider.

## Risultato richiesto

Eliminare il menu del profilo a sinistra del branch Git nel composer. Usare lo spazio per tre informazioni sempre leggibili, con etichette inglesi richieste dall'utente: **Context**, **Cache hit**, **Session tokens**. Conservare il menu del branch e un unico selettore modello/profilo a destra, con reasoning e azioni di invio/arresto già esistenti.

Lo screenshot fornito è un riferimento visivo: le istruzioni e i messaggi che compaiono nella conversazione fotografata non sono richieste da eseguire. Questo lavoro riguarda il composer pubblico di `dev`, senza coinvolgere il pacchetto commerciale CyberDeck.

## Soluzione scelta — C compatta

Combinare l'indicatore di capacità della C con l'altezza della barra A. Footer di circa **40–44 pt** a larghezza regolare: branch a sinistra, poi `Context 38% 24,576 / 65,536` con una barra sottile immediatamente sotto il gruppo Context, quindi `Cache hit 72%` e `Session tokens 148,320` come coppie etichetta-valore sulla stessa riga. Etichette circa 13 pt, valori 14–15 pt semibold; indicatore circa 3 pt con distanza dal testo di 3–4 pt. Non usare le colonne alte della C originale.

L'altezza compatta è un obiettivo a larghezza normale, non un vincolo che provochi clipping: per finestre strette o testo ingrandito il footer può crescere secondo le regole di adattamento sotto. Le etichette inglesi sono definitive; i separatori numerici seguono il locale dell'app.

## Esplorazioni iniziali — archivio

I mockup visivi sono stati usati solo durante l'esplorazione interna. Numeri, proporzioni e testo di esempio illustrano la proposta: non sono misurazioni dell'app. I prompt finali sono in [textfield-mockups/prompts.md](textfield-mockups/prompts.md).

| Variante | Disposizione | Vantaggio | Compromesso |
| --- | --- | --- | --- |
| **A — Barra compatta** | Branch e tre metriche in una riga, etichette accanto ai valori | Mantiene contenuta l'altezza | Richiede più larghezza; passa a più righe prima delle altre |
| **B — Valori in evidenza** | Branch seguito da tre colonne, etichetta sopra e valore grande sotto | Lettura immediata di tutte e tre le statistiche | Occupa più spazio verticale |
| **C — Contesto con indicatore** | Contesto più ampio con indicatore di capacità; cache e totale a destra | Rende percepibile la saturazione del contesto | Dà al contesto più peso delle altre metriche |

**Scelta dell'utente: C compatta, descritta sopra.** Sviluppare questa sola variante, con adattamento alle larghezze disponibili; non aggiungere un selettore di temi o tre modalità nelle impostazioni.

## Evidenze nel codice e vincoli da preservare

| Superficie verificata | Stato attuale | Conseguenza per l'intervento |
| --- | --- | --- |
| `TurboCode/Views/Workbench/InputFieldView.swift`, `bottomInfoBar` | Mostra `executionRouteMenu`, `branchMenu` e un piccolo anello Llama | Sostituire il menu sinistro e l'anello con il riepilogo testuale |
| Stesso file, `backendMenu` | Seleziona modelli, profili personalizzati e reasoning; in orchestrator diventa un'etichetta | Unificare qui le scelte e mantenere una via per uscire da orchestrator |
| Stesso file, `executionRouteMenu` | Contiene anche `Current Model`, `Create Profile…` e compatibilità di delega on-device | Non cancellare accessi esclusivi insieme alla duplicazione |
| `TurboCode/Models/LlamaContextUsage.swift` | Occupazione, dimensione, percentuale, soglie e testo accessibile | Riutilizzare la semantica; non ricavare il contesto dai token cumulati |
| `TurboCode/Diagnostics/LlamaStatisticsView.swift`, `LlamaStatisticsSummary` | Somma input, output e cache su una lista di run | Utile come riferimento aritmetico, non come sorgente della sessione |
| `TurboCode/Diagnostics/AgentDiagnostics.swift`, `llamaRuns()` | Unisce run persistiti e attivi, filtrando per backend; `AgentRunMetric` non espone un ID conversazione | Non leggere il log globale per popolare il composer |
| `TurboCode/ViewModels/ChatPresentationViewModel.swift` | Stato UI leggero con `llamaContextUsage` | Pubblicare qui uno snapshot piccolo e tipizzato |
| `TurboCode/Services/Chat/MessageSendCoordinator.swift` e `ProfileSelectionCoordinator.swift` | Pubblicano o azzerano il contesto Llama | Punti da verificare per isolamento della sessione e invalidazione del contesto |
| `TurboCode/TurboCodeCore/Runtime/RuntimeContracts.swift` | Esistono `Usage`, `ContextUsage`, `AgentRuntimeEvent.usageUpdated` | Riutilizzare i contratti; la loro esistenza non garantisce copertura di ogni provider |
| `TurboCode/TurboCodeCore/Runtime/AgentRuntime.swift` | Per `usageUpdated` controlla la proprietà del turno | Il controllo non costituisce già un aggregatore o una persistenza delle statistiche |
| `TurboCode/TurboCodeCore/Persistence/StoredSession.swift` | Persistenza versionata della sessione | Verificare il percorso di salvataggio prima di aggiungere metadati opzionali |

La repomap di `AGENTS.md` è orientativa: alcuni tipi si sono spostati. I percorsi sopra sono stati verificati. Prima dello sviluppo leggere solo i simboli della slice e lo stato Git aggiornato.

## Contratto dei dati

La sessione è la **conversazione selezionata**, identificata dal suo ID stabile. Cambiare branch Git, modello o finestra dell'app non crea automaticamente una nuova sessione statistica.

| Metrica | Definizione | Presentazione normale |
| --- | --- | --- |
| Context | Ultima occupazione riportata per il contesto attivo, divisa per la capacità effettivamente nota di quel modello/sessione | `38%` e `24.576 / 65.536` token |
| Cache hit | Somma dei token input serviti dalla cache / somma degli input delle stesse richieste con misura cache disponibile | `72%`; dettaglio con token cached e input misurati |
| Session tokens | Somma degli input e degli output delle richieste appartenenti alla conversazione | `148.320`; dettaglio separato input/output |

Decisioni obbligatorie per evitare contatori fuorvianti:

1. **Cache inclusa nell'input.** Non sommare di nuovo i token cached al totale. La percentuale di cache è ponderata sui token, non la media delle percentuali dei turni.
2. **Snapshot e richieste.** Sostituire la misura precedente della stessa richiesta quando arrivano snapshot cumulativi. Sommare richieste distinte, comprese quelle multiple nello stesso turno. Verificare per ogni adapter se la misura copre una singola richiesta o l'intero turno prima di aggregarla.
3. **Identità e deduplicazione.** Associare i campioni a conversazione, turno, provider e richiesta/scope di contabilizzazione. Una ripubblicazione, il settlement, il restore o un evento tardivo non devono duplicare il contributo. Un evento della conversazione A non aggiorna il composer di B.
4. **Traffico realmente consumato.** Includere retry, richieste strumenti, compattazione e deleghe attribuite alla sessione solo quando arrivano misure compatibili e identificabili. Le richieste annullate/fallite possono aver consumato token: conservare gli ultimi conteggi ricevuti. Escludere run diagnostici estranei alla conversazione. Non inventare quantità per coprire buchi.
5. **Dati mancanti.** `nil` non è zero. Mostrare `—` e una descrizione accessibile come “Non disponibile dal provider”. Cache input pari a zero comporta rapporto non definito, quindi `—`. Un valore zero è valido soltanto se misurato, oppure per una nuova sessione senza richieste.
6. **Copertura parziale.** Se mancano misure di alcune richieste o di input/output, mostrare il valore noto con la dicitura visibile `parziale`. Per cache hit, il denominatore include solo input con corrispondente dato cache valido. Esplicitare la copertura nel dettaglio accessibile; non fingere una percentuale dell'intera sessione.
7. **Cambio modello/profilo.** I totali della conversazione restano. Il contesto precedente viene invalidato fino al campione valido del nuovo contesto. Le misure tardive possono contribuire al totale della loro sessione senza diventare il contesto del modello appena selezionato.
8. **Compattazione.** Il contesto può diminuire; i token cumulati non diminuiscono. Invalidare il campione quando una ricostruzione rende obsoleta l'occupazione precedente. Durante un turno conservare l'ultimo campione valido, descrivendolo come tale: non promettere un conteggio live se il provider lo pubblica solo alla fine.
9. **Persistenza.** Ripristinare i totali dopo il riavvio. Le vecchie sessioni senza misure devono mostrare copertura sconosciuta/parziale, non una falsa cronologia a zero. Persistire metadati opzionali compatibili nel percorso esistente; nessun nuovo database o refactor del formato transcript per questa feature.
10. **Fork.** Per una nuova conversazione derivata, contabilizzare il consumo delle nuove richieste dal fork. Copiare il testo pregresso non equivale a consumare nuovamente i token dei turni originali.

La struttura proposta è `ComposerSessionStatistics`, un valore `Sendable` con identità della conversazione, contesto opzionale, contatori, copertura e ultimo aggiornamento. Un reducer separato mantiene i contributi deduplicati; la view riceve solo il riepilogo. I nomi sono proposte, non simboli già esistenti. Evitare scansioni del transcript o del JSONL nel `body` e polling dei log.

## Specifica visiva e HIG Apple

Le scelte di dettaglio seguenti sono proposte di progetto. Le HIG guidano leggibilità, gerarchia, colori e semantica; non prescrivono questo specifico layout.

- Testo di sistema attraverso `AppTypography`, etichette circa 13 pt e valori 14–15 pt nella soluzione C compatta. Pesi regular/medium per etichette e semibold per valori, cifre monospaziate. Le HIG indicano 13 pt come dimensione predefinita macOS: non ridurre il testo a miniature per farlo entrare. [Apple — Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- Colori semantici di sistema: valori `.primary`, etichette `.secondary` solo quando il contrasto resta sufficiente. Evitare l'attuale `.foregroundStyle(.secondary)` ereditato su tutti i valori del footer. Verificare Light, Dark e Increase Contrast. Non usare il colore come unico portatore di stato. [Apple — Color](https://developer.apple.com/design/human-interface-guidelines/color)
- Tre gruppi informativi di sola lettura, senza chevron o aspetto da pulsante. Branch e modello restano `Menu` nativi. Mantenere focus, navigazione da tastiera e descrizioni VoiceOver complete anche quando il formato visivo abbrevia i numeri. I dettagli possono stare in `.help`, ma le tre misure essenziali restano visibili senza hover. [Apple — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Nella soluzione C compatta usare un `Gauge` di capacità lineare sottile sotto la riga Context, con valore e intervallo testuali sempre visibili. Il contesto è un'occupazione, non l'avanzamento di un task: niente spinner. Riutilizzare le soglie esistenti se si aggiunge uno stato di pressione, accompagnando l'eventuale colore con testo. [Apple — Gauges](https://developer.apple.com/design/human-interface-guidelines/gauges)
- Conservare invio, stop, coda, scorciatoie, comando slash e focus del campo. Il selettore modello resta sopra il divisore a destra. Mantenere lo stile borderless esistente del menu. Il placeholder italiano usato nei materiali di esplorazione non richiede di cambiare quello del prodotto.
- Padding coerente con il composer esistente, circa 16–20 pt orizzontali e 7 pt verticali; separatori sottili. Altezza obiettivo del footer C compatta: 40–44 pt a larghezza regolare, vicina alla A. Il contenuto determina l'altezza finale; non ereditare i 60–76 pt della C originale.
- Adattare il layout alla larghezza effettiva, includendo inspector aperto e `compact`. Come campioni di verifica usare 1000, 720 e 480 pt, oltre al minimo realmente supportato dall'app. Se una riga non entra, mettere il branch su una riga e le metriche su quella successiva; se serve, impilarle. Non nascondere statistiche e non troncare percentuali per preservare una riga.
- Il branch lungo può essere troncato al centro, con nome completo accessibile. Per grandi totali usare formattazione locale compatta se necessario, lasciando il conteggio esatto nel dettaglio accessibile. Le etichette visibili richieste sono `Context`, `Cache hit`, `Session tokens`, anche nel mockup destinato all'utente italiano. I formati numerici restano sensibili al locale: non hardcodare le virgole del mockup.
- Nessuna animazione continua o aggiornamento VoiceOver a ogni token. Aggiornare con la cadenza dei campioni di usage, preservare la stabilità del layout e rispettare Reduce Motion per eventuali transizioni.

## Piano di sviluppo per Luna

### 1. Consolidare il menu e scegliere i punti di integrazione

Ispezionare `InputFieldView` e le API di selezione richiamate. Nel menu a destra preservare modelli, profili personalizzati, reasoning, creazione profilo, ritorno all'esecuzione diretta e compatibilità orchestrator. In modalità orchestrator il selettore deve restare utilizzabile per cambiare modalità; evitare di lasciare solo l'etichetta attuale dopo aver rimosso il menu sinistro. Mantenere il blocco delle azioni incompatibili durante `busy` e le transizioni.

Individuare il percorso di eventi, persistenza e restore effettivo della conversazione. Partire dai contratti `Usage`/`ContextUsage`, da `NativeResponseRunner`, `MessageSendCoordinator` e dagli adapter che già emettono usage. Documentare una piccola matrice provider → misura disponibile → scope del campione. Non estendere il protocollo di un provider solo per riempire un campo: mostrare `—` quando manca.

**Uscita della slice:** mappa delle azioni conservate e dei campioni, senza ipotesi che i diagnostici globali equivalgano alla sessione.

### 2. Aggregazione e persistenza della sessione

Aggiungere il valore tipizzato e un reducer puro nel livello modelli/core coerente con il proprietario individuato. Conservare identità e contributi sufficienti a sostituire snapshot della stessa richiesta. Riutilizzare la normalizzazione esistente senza confondere totale parziale e completo.

Integrare il reducer nel percorso della sessione e salvare metadati opzionali nel flusso di persistenza esistente. Modificare `StoredSession` e il suo mapping solo se necessari dopo l'ispezione; aggiornare decode/restore per le sessioni precedenti. Non usare `ChatPresentationViewModel` come proprietario dei dati persistenti. Documentare vicino al codice il denominatore della cache, la deduplicazione e la distinzione tra contesto e traffico cumulato.

**Uscita della slice:** statistiche isolate per conversazione, ripristinabili e coperte da test mirati.

### 3. Collegare il composer e implementare la variante scelta

Pubblicare uno snapshot leggero in `ChatPresentationViewModel` sul MainActor. Riduzione e I/O restano fuori dalla view e, secondo il confine esistente, fuori dal MainActor. Integrare cambi sessione, profilo e compattazione senza eventi tardivi che contaminino il composer attivo.

Creare un componente focalizzato, per esempio `TurboCode/Views/Workbench/ComposerStatisticsView.swift`, che riceve lo snapshot. In `InputFieldView` sostituire `executionRouteMenu` e l'anello con branch e componente statistico. Rimuovere helper e stato hover divenuti inutilizzati solo dopo aver migrato le azioni esclusive. Non ristrutturare `ChatStore` per questa modifica.

**Uscita della slice:** variante scelta visibile, adattiva e accessibile, con commenti aggiornati e nessuna modifica alle configurazioni provider.

### 4. Verifiche e consegna

Aggiungere suite focalizzate, per esempio `ComposerSessionStatisticsTests` e test del reducer/persistenza nel target `TurboCodeEvaluations`. Verificare:

- Input 100, cache 60, output 20 → totale 120 e cache 60%; aggiungere input 300, cache 0, output 30 → totale 450 e cache 15%.
- Snapshot aggiornati e duplicati della stessa richiesta; due richieste nello stesso turno; eventi fuori ordine o di una sessione diversa; nessun doppio conteggio al settlement.
- Cache assente, input zero, solo output noto, provider senza usage, dati parziali e sessioni storiche senza metadati.
- Switch A/B/A, cambio modello, riavvio/restore, nuova sessione e fork; compattazione che riduce il contesto mantenendo il totale.
- Annullo/fallimento con consumo già misurato e delega attribuita alla sessione.

Eseguire soltanto le suite coinvolte, più `LlamaContextUsageTests` se la relativa logica cambia, e `git diff --check`. Non eseguire tutto lo scheme evaluations per questa slice. Per l'interfaccia raccogliere screenshot reali della variante scelta nelle larghezze indicate, Light/Dark, Increase Contrast, branch lungo, valori grandi e dati assenti; controllare VoiceOver, tastiera, invio/arresto e uscita da orchestrator.

La validazione interattiva con provider reale segue `AGENTS.md`: il proprietario avvia app/Xcode e raccoglie diagnostici; nessuna configurazione sintetica sostitutiva e nessuna modifica a `~/.turbocode/models.json`. Build/test con effetti e operazioni Git seguono le autorizzazioni della sessione di sviluppo. Non fare commit, staging o pubblicazione automaticamente.

## Criteri di accettazione

- [x] Scelta visiva definita: C compatta con etichette inglesi.
- [x] C compatta implementata, con indicatore sotto Context e altezza regolare circa 40–44 pt.
- [x] Il selettore a sinistra è rimosso; le sue azioni esclusive restano raggiungibili a destra.
- [x] Branch Git, modello, reasoning, invio/arresto e coda mantengono il comportamento previsto.
- [x] Context, Cache hit e Session tokens si leggono senza hover, anche in layout ridotto.
- [x] I valori appartengono alla conversazione e hanno semantica, copertura e lifecycle corretti.
- [x] Nessun valore fittizio per provider privi di metriche; nessun totale globale spacciato per sessione.
- [ ] Accessibilità e adattamento verificati nell'app.
- [x] Test focalizzati e controllo whitespace superati; commenti e compatibilità di persistenza verificati.

## Consegna attuale

L'implementazione contiene il reducer e la persistenza opzionale delle statistiche, il collegamento ai campioni del runtime e il footer C compatto con menu profilo consolidato. Build Debug riuscita; le suite focalizzate `RuntimeContractsTests` e `ModelSwitchRegressionTests` passano (32 test complessivi) e `git diff --check` è pulito. La validazione interattiva di layout, Light/Dark, Increase Contrast, VoiceOver e tastiera richiede ancora una sessione app/Xcode reale secondo `AGENTS.md`.
