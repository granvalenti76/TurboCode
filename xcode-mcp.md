# Xcode MCP + TurboCode ACP — Piano di implementazione

Data: 10 settembre 2026. Branch esaminato: `dev`, checkpoint `eb1b406`.

## Obiettivo e decisioni concordate

Integrare TurboCode e Xcode in entrambe le direzioni:

1. **TurboCode → Xcode, tramite MCP:** il modello attivo nell'app TurboCode può
   utilizzare gli strumenti del servizio MCP ufficiale di Xcode.
2. **Xcode → TurboCode, tramite ACP:** l'utente seleziona TurboCode come agente
   nel pannello Intelligence di Xcode e utilizza il harness dalla UI di Xcode.

Il risultato deve riutilizzare il runtime e i profili TurboCode. Le due UI
possono ospitare istanze e conversazioni indipendenti dello stesso motore.
Non è richiesta la sincronizzazione in tempo reale delle conversazioni tra app
e Xcode.

### Filosofia del loop

Il modello riceve obiettivo, contesto e strumenti e decide autonomamente come
procedere. Non introdurre fasi obbligatorie di pianificazione, editing, build
o verifica, né un secondo orchestratore deterministico sopra il modello.

Il caso principale è un singolo modello/profilo, per esempio Llama o Codex.
La delega è facoltativa. Quando viene utilizzata, la verifica del compito resta
responsabilità dell'orchestratore: non trasformare la verifica automatica del
worker in un prerequisito di questa integrazione.

Il harness governa lifecycle, autorizzazioni applicabili, workspace, trasporto,
cancellazione ed evidenze. La scelta delle azioni rimane al modello.

## Stato del piano e ambito dell'autorizzazione

### Aggiornamento implementazione — Slice MCP iniziali

La prima implementazione MCP è ora presente sul branch `dev`: il contratto
locale di Xcode 27 è stato verificato tramite `mcpbridge --help` e conferma un
bridge JSON-RPC stdio con `xcrun mcpbridge`. Sono state implementate le slice
del client/trasporto e del normale loop TurboCode: discovery paginata,
connessione lazy mantenuta fra turni, timeout, cancellazione, errori RPC
distinti dagli errori del tool, gateway `xcode_mcp` opt-in per Foundation Models
e Codex, capability catalogata, impostazione Agents e test focalizzati.

Il client usa il contratto MCP osservato (`initialize`,
`notifications/initialized`, `tools/list`, `tools/call`) e non inventa un
catalogo Xcode. La verifica di compatibilità end-to-end con un progetto aperto,
il permesso Intelligence di Xcode e l'uso reale di ciascun tool richiede ancora
una sessione interattiva autorizzata; non è stata dichiarata completata dai
mock.

È iniziata anche la parte ACP. Il branch contiene il dispatcher JSON-RPC stdio
con `initialize`, `session/new`, `session/prompt`, `session/cancel`, update
streaming e gestione degli errori con ID correlato. `ACPRuntimeDriver` separa
identità/sessione/workspace dal runtime applicativo e riceve il motore condiviso
tramite `ACPApplicationRuntime`. `ACPApplicationRuntimeAdapter` collega ora
`AgentRuntime` e `LLMRuntime`, ricostruisce la sessione Foundation Models con il
profilo/workspace ACP e proietta testo, tool e usage verso ACP. La destinazione
delle approvazioni è iniettata nei tool: il processo headless invia
`session/request_permission` al client e risolve il registro esistente senza
bloccare il dispatcher. Il target `turbocode-acp` è ora embeddato dall'app in
`Contents/Helpers/turbocode-acp`, con firma on-copy e documentazione per la
registrazione manuale in Xcode.
Le suite ACP focalizzate verificano protocollo, isolamento delle sessioni e
cancellazione, incluse permission e packaging; non attestano ancora l'avvio
reale da Xcode o l'esecuzione di un provider reale.

Questo documento è il deliverable di pianificazione richiesto dall'utente.
Non attesta che le integrazioni siano già completamente implementate o
validate. Il lavoro ACP prosegue per incrementi verificabili.

La richiesta di scrivere questo file non autorizza registrazioni in Xcode,
modifiche alla configurazione locale, Git mutation, installazioni o esecuzioni
interattive. Durante l'implementazione seguire l'incarico ricevuto e `AGENTS.md`;
non richiedere nuovamente approvazioni già comprese in quell'incarico.

Lavorare sul codice pubblico di `dev`. Non importare sorgenti, asset o test del
CyberDeck commerciale dal branch `cyberdeck`.

## Ricognizione già eseguita

- Sul Mac esaminato, `xcode-select -p` restituisce
  `/Applications/Xcode.app/Contents/Developer`.
- Il bundle Xcode dichiara versione `27.0`.
- `xcrun --find mcpbridge` restituisce
  `/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge`.
- Non è stata avviata una connessione MCP né registrato un agente ACP.
- La schermata fornita dall'utente mostra **Add an ACP Agent**, con campi
  **Name**, **Executable** e **Interpreter** opzionale.
- `xcode_project` esiste già e usa servizi CLI per discovery, build e test.
- Esiste un client MCP Safari con trasporto stdio e un gateway di strumenti.
- Il runtime ha già contratti per turni, eventi, ricevute e cancellazione.
- `TurboCodeCore` è ancora una directory compilata nel target dell'app, non
  una libreria pubblica pronta da collegare a un eseguibile separato.
- L'assembly applicativo costruisce anche store e componenti UI. L'avvio senza
  UI richiede un'estrazione mirata, non solo un nuovo entry point.

Questi sono fatti osservati, non assunzioni da hardcodare. Ricontrollare branch,
working tree, toolchain e contratti all'inizio dell'implementazione.

## Architettura desiderata

```text
App TurboCode ───────────────────────┐
                                    ↓
                              Runtime TurboCode ↔ modello del profilo
                                    ↕
Xcode Intelligence ↔ ACP ↔ helper ───┘
                                    ↕
                            adapter strumenti MCP
                                    ↕
                         client MCP / trasporto
                                    ↕
                           servizio MCP Xcode
```

Il diagramma indica riuso del codice, non una singola sessione globale condivisa
tra processi. Ogni sessione ACP deve avere identità, workspace e stato propri.

### Ruoli dei protocolli

- **MCP:** TurboCode è client; Xcode fornisce strumenti e relativi risultati.
- **ACP:** Xcode è client; TurboCode è l'agente che riceve prompt ed emette
  aggiornamenti, richieste di autorizzazione e risultati.

Non confondere ACP con un endpoint OpenAI-compatible: esporre un modello HTTP
non equivale a registrare il harness TurboCode come agente.

## Slice 1 — Verificare i contratti reali

### Attività

1. Identificare l'esperienza MCP supportata da Xcode installato. Apple documenta
   `xcrun mcpbridge`; le release note di Xcode 27 descrivono anche un servizio
   utilizzabile senza un workspace già aperto. Non assumere che la procedura
   storica sia l'unica disponibile.
2. Con l'autorizzazione necessaria alla prova interattiva, verificare accesso,
   lifecycle e discovery. Acquisire il catalogo reale con nomi, descrizioni,
   input schema, output, versioni e capacità negoziate.
3. Verificare identificazione di progetto/workspace, più progetti disponibili,
   selezione di schema e destinazione e validità degli handle dopo riavvio.
4. Verificare rappresentazione di immagini, riferimenti a risorse, diagnostica,
   errori, progress e operazioni lunghe.
5. Verificare il contratto ACP effettivamente usato da Xcode: inizializzazione,
   creazione sessione, prompt, aggiornamenti, cancellazione, permessi e capacità
   opzionali. Non implementare una bozza ACP futura supponendo che sia supportata.
6. Verificare se Xcode fornisce server MCP nella creazione della sessione ACP,
   con quale trasporto e quale contesto. Riutilizzarli quando disponibili senza
   aprire una seconda connessione equivalente.

### Deliverable

Fixture sanitizzate dei messaggi rilevanti e una matrice sintetica di capacità
osservate. Non conservare credenziali, transcript privati o dati del progetto
dell'utente nelle fixture.

### Criterio di uscita

Il piano tecnico usa il contratto reale della toolchain e distingue chiaramente
capacità disponibili, non supportate e ancora da verificare.

## Slice 2 — Client MCP Xcode nativo

### Componenti proposti

Nomi indicativi, da adattare alle convenzioni esistenti senza moltiplicare layer:

- `Services/MCP/MCPStdioTransport.swift`: processo, framing JSON-RPC, ID delle
  richieste, risposte, notifiche, stderr separato e chiusura.
- `Models/MCP/MCPToolDescriptor.swift`: descrittore di uno strumento scoperto.
- `Models/MCP/MCPToolResult.swift`: contenuti tipizzati, errori e riferimenti.
- `Services/Xcode/XcodeMCPClient.swift`: lifecycle Xcode, catalogo e invocazioni.

Implementare solo i trasporti richiesti dalle modalità Xcode validate nella
slice 1. Se ACP fornisce un trasporto diverso da stdio, includerlo esplicitamente
nel perimetro necessario; non fingere di supportarlo mediante conversioni.

### Comportamento

- I/O ed esecuzione fuori dal MainActor; attori solo per stato condiviso reale.
- Una connessione mantenuta fra turni, avviata dal collegamento esplicito o
  dall'effettiva necessità del workflow concordato.
- Negoziazione del protocollo compatibile con il server osservato.
- Discovery completa, inclusa paginazione o cambi di catalogo se supportati.
- Timeout separati per avvio e chiamate lunghe; progress quando disponibile.
- Stop inoltrato secondo il protocollo negoziato; non confondere chiusura del
  bridge con prova dell'arresto di una build o di un'azione nel servizio Xcode.
- Disconnessione durante una mutazione classificata come esito incerto.
  Nessun retry automatico di un'azione con effetti già potenzialmente applicati.
- Limiti di messaggio e gestione di JSON malformato o risposte tardive.
- Il client non accede a `ChatStore` e non genera presentazione direttamente.

Riutilizzare concetti del client Safari e del trasporto plugin dove utile.
Non estendere la slice a una rifattorizzazione generale di quelle integrazioni.

### Criterio di uscita

Il client scopre e invoca strumenti Xcode e gestisce errori, Stop e riconnessione
con test di protocollo indipendenti dalla UI.

## Slice 3 — Strumenti MCP nel normale loop TurboCode

### Esposizione ai profili

- Aggiungere una capability di profilo **Xcode MCP**.
- Importare dinamicamente nomi, descrizioni e schemi pubblicati dal server,
  con alias stabili dove richiesti dal provider.
- Acquisire il catalogo al collegamento e includerlo nella successiva costruzione
  della sessione. Non modificare a metà turno il catalogo della sessione attiva.
- Conservare schemi completi e validi: non troncare JSON schema per risparmiare
  contesto. Dichiarare gli schemi non rappresentabili dal backend.
- Coprire parametri opzionali, enum, oggetti e array effettivamente presenti.
  L'adapter TypeScript attuale non va assunto come convertitore universale.
- Integrare i percorsi Foundation Models/compatibili, incluso Llama, e gli
  strumenti dinamici del bridge Codex.
- Tenere distinte abilitazione della capability e disponibilità della connessione.

### Risultati e contesto

- Usare gli eventi e il gate del turno esistenti per tool start/end e ricevute.
- Preservare `isError` e distinguere errore RPC da errore restituito dal tool.
- Conservare testo, immagini e risorse senza appiattirli preventivamente.
- Rendere le immagini nella UI e passarle al modello solo attraverso un adapter
  che le supporti realmente; altrimenti rendere esplicita la limitazione.
- Per output grandi, offrire sintesi e accesso al contenuto completo senza
  eliminare gli errori conclusivi o lo stato della verifica.
- Associare progetto e handle al workspace della sessione; invalidarli dopo
  cambio workspace, restart o riconnessione. Con più corrispondenze plausibili,
  chiedere una selezione invece di agire su un progetto arbitrario.
- Gli edit Xcode devono aggiornare le proiezioni del workspace. Non promettere
  l'Undo transazionale o il controllo revisioni di `edit_file` per operazioni
  che non attraversano quei meccanismi.

`xcode_project`, Bash ed editing nativo restano strumenti utilizzabili secondo
il profilo. Le descrizioni devono chiarire le differenze senza obbligare il
modello a un percorso fisso o esporre duplicati dello stesso collegamento MCP.

### Interfaccia

Controllo **Xcode MCP** nelle impostazioni: collegamento, stato, eventuale azione
richiesta da Xcode e progetto associato. UI minimale e nativa.

### Criterio di uscita

Un modello principale può usare Xcode dal normale loop di TurboCode, senza
delega obbligatoria e senza un nuovo workflow deterministico.

## Slice 4 — Runtime avviabile senza UI

### Obiettivo

Preparare il motore condiviso necessario a un helper ACP. Il punto di partenza
è `ChatApplicationAssembly`, non l'istanziazione di `TurboCodeApp` o di una
finestra invisibile.

### Attività

- Individuare il minimo insieme di runtime, factory, servizi e strumenti da
  compilare in un modulo interno condiviso da app e helper.
- Separare la costruzione delle dipendenze eseguibili dalle proiezioni UI.
- Riutilizzare `AgentRuntime`, `LLMRuntime`, session factory e adapter provider;
  non creare un secondo loop ridotto per ACP.
- Iniettare workspace, profilo, credenziali, persistenza e output port.
- Rendere sostituibile la destinazione delle approvazioni: UI TurboCode nel
  desktop host, richieste ACP nel nuovo host.
- Eliminare solo le dipendenze UI che impediscono questo avvio. Nessuna
  estrazione generalizzata di tutto il repository e nessuna nuova API pubblica
  di TurboCodeCore richiesta da questa feature.
- Verificare lifecycle e requisiti dei backend nel processo helper, inclusi
  disponibilità Foundation Models, firma ed eventuali entitlement necessari.

### Criterio di uscita

Un host senza UI esegue un turno con gli stessi servizi del desktop host,
riceve gli eventi e cancella correttamente. I test del percorso app restano verdi.

## Slice 5 — Agente ACP `turbocode-acp`

### Eseguibile e protocollo

Creare un target Swift command-line distribuito con l'app. Il nome proposto è
`turbocode-acp`; il percorso definitivo sarà stabilito dal packaging.

- ACP su stdio: stdout riservato ai messaggi di protocollo, log su stderr.
  Verificare anche i log dei componenti condivisi che oggi usano `print`.
- Supportare inizializzazione e negoziazione delle capacità effettive.
- Implementare creazione sessione, prompt, aggiornamenti streaming,
  cancellazione e risposte terminali.
- Implementare richieste di autorizzazione attraverso il client Xcode senza
  bloccare il dispatcher dei messaggi mentre attende l'utente.
- Tradurre eventi e ricevute in aggiornamenti ACP: testo, attività, posizioni
  nei file, diff e contenuti supportati. Non tentare di inviare widget SwiftUI.
- Non pubblicare capacità opzionali finché non sono implementate e collaudate.

### Sessioni e progetto

- Workspace derivato dal contesto ACP e validato per la sessione.
- Identità di sessione e turno stabili; nessuno stato globale di "progetto attivo"
  condiviso fra conversazioni indipendenti.
- Usare eventuali server MCP forniti da Xcode, senza duplicarne l'esposizione.
- Gestire i contenuti allegati al prompt e i buffer non salvati tramite le
  capacità filesystem/editor effettivamente negoziate. Rendere coerenti letture,
  revisioni ed edit: non applicare su disco una patch calcolata su altro contenuto.
- Stabilire esplicitamente il comportamento quando un backend non supporta un
  contenuto ricevuto, invece di scartarlo silenziosamente.
- Le sessioni ACP non riusano la conversazione visibile nell'app. La persistenza
  deve evitare scritture concorrenti degli stessi file fra app e helper.
- Ripristino tramite ACP solo quando implementato con replay coerente; non
  dichiarare `loadSession` prima di avere questa garanzia.

### Modelli e profili

L'utente sceglie un profilo TurboCode destinato a Xcode. Se il client Xcode
supporta i controlli ACP necessari, esporre la selezione lì; altrimenti usare
il profilo configurato nell'app. Rendere identificabile il profilo in uso.

Provider e modelli provengono dalla configurazione esterna esistente.
`~/.turbocode/models.json` resta la ground truth e non va modificato dai test.
Nessun modello o endpoint hardcoded. Credenziali nel Keychain: verificare la
possibilità di accesso dell'helper firmato e documentare eventuali modifiche
necessarie a firma o entitlement, senza assumere che l'accesso sia ereditato.

### Criterio di uscita

Xcode avvia l'eseguibile, crea una sessione, mostra il testo e gli strumenti,
presenta le autorizzazioni e interrompe il turno. Il modello resta il decisore.

## Slice 6 — Distribuzione, documentazione e validazione

### Packaging e registrazione

- Distribuire l'helper firmato con l'app in un percorso stabile rispetto alla
  posizione del bundle. Evitare riferimenti a DerivedData o al checkout locale.
- Gestire architettura, dipendenze, aggiornamenti dell'app e directory corrente
  del processo avviato da Xcode.
- Documentare i campi **Add an ACP Agent**:
  - Name: `TurboCode`.
  - Executable: percorso assoluto dell'helper realmente distribuito.
  - Interpreter: vuoto per l'eseguibile Swift nativo.
- Valutare eventuale registrazione mediante plugin Xcode solo dopo verifica
  del contratto ufficiale. Il percorso manuale della schermata è sufficiente
  per la prima versione.
- Nessuna modifica automatica alla configurazione Xcode fuori dall'autorizzazione
  ricevuta per l'implementazione e la prova interattiva.

### Scenari di accettazione

| Scenario | Evidenza richiesta |
| --- | --- |
| App TurboCode → Xcode MCP | Discovery e uso degli strumenti da un normale turno del modello principale |
| Xcode → TurboCode ACP | TurboCode selezionabile e avviabile dalla UI Intelligence |
| Coding con profilo Llama | Esplorazione, modifica, build/test e interpretazione del risultato |
| Altro backend configurato, incluso Codex | Stesso contratto tool/eventi, con limiti del provider dichiarati |
| Preview SwiftUI | Immagine visibile e accessibile al modello quando supportato |
| Stop durante una chiamata | Cancellazione propagata; stato incerto dichiarato se l'arresto non è confermato |
| Approvazione pendente | UI corretta, risposta recapitata e Stop senza deadlock |
| Più progetti o cambio workspace | Nessuna operazione indirizzata mediante un handle obsoleto |
| Buffer non salvato | Lettura/edit coerenti con il contenuto utilizzato per calcolare la modifica |
| Riavvio servizio/helper | Recupero esplicito senza duplicare mutazioni o messaggi |

### Test

Test Swift Testing mirati, con trasporti e provider simulati per i contratti:
framing parziale, ID e risposte fuori ordine, errori, catalogo, schemi opzionali
e annidati, contenuti multipli, timeout, cancellation, late events, session
isolation e approvazioni. Verificare che il flusso stdio ACP non sia contaminato
da diagnostica stampata su stdout.

Usare prove reali per compatibilità Xcode e provider: secondo `AGENTS.md`, quando
necessario chiedere all'utente di eseguire la sessione interattiva e raccogliere
i diagnostici. Non sostituire questa verifica con una configurazione sintetica
e non dichiarare completata l'accettazione sulla sola base dei mock.

Eseguire solo suite pertinenti alle slice e `git diff --check`. La suite completa
richiede un gate esplicitamente autorizzato. Ogni commit richiede l'autorizzazione
Git prevista dal repository e un body che documenti problema, soluzione e verifica.

## Superfici esistenti da consultare

Leggere in modo mirato i simboli necessari; questo elenco non impone di
modificare tutti i file.

- `TurboCode/Services/SafariMCPClient.swift`
- `TurboCode/Tools/SafariMCPTool.swift`
- `TurboCode/Services/Xcode/XcodeProjectService.swift`
- `TurboCode/Tools/Xcode/XcodeProjectTool.swift`
- `TurboCode/Services/Chat/ModelSessionFactory.swift`
- `TurboCode/Services/Chat/LLMRuntime.swift`
- `TurboCode/Services/Chat/BackendEventIngress.swift`
- `TurboCode/Services/Codex/CodexTurboCodeToolBridge.swift`
- `TurboCode/Tools/Plugins/TypeScriptPluginToolAdapter.swift`
- `TurboCode/Stores/ChatApplicationAssembly.swift`
- `TurboCode/Stores/CredentialStore.swift`
- `TurboCode/Tools/FileSystemTool.swift` (approvazioni e path validation)
- `TurboCode/Models/ModelToolCatalog.swift`
- `TurboCode/Models/AgentTuningConfig.swift`
- `TurboCode/Views/Settings/SettingsView.swift`
- `TurboCode/TurboCodeCore/Runtime/AgentRuntime.swift`
- `TurboCode/TurboCodeCore/Runtime/RuntimeContracts.swift`
- `TurboCode/TurboCodeCore/README.md`
- `TurboCode.xcodeproj/project.pbxproj`

Aggiornare `CONFIGURATION.md` e la documentazione di prodotto relativa a Xcode,
profili e strumenti quando i comportamenti sono implementati. Aggiornare questo
piano con risultati e limiti osservati; non trasformare assunzioni in fatti.

## Fuori ambito

- Nuovo sistema di orchestrazione o verifica obbligatoria.
- Rifattorizzazione dei worker/delega.
- Sincronizzazione live della stessa conversazione fra app e Xcode.
- Migrazione generale della persistenza o introduzione di grafi agentici.
- Riscrittura delle integrazioni Safari/plugin.
- Pubblicazione di un SDK pubblico TurboCodeCore.
- Desktop automation per pilotare Xcode al posto di MCP/ACP.

## Fonti ufficiali

Consultate durante la pianificazione; riconfermare il contratto della versione
installata prima di implementare.

- Apple — [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- Apple — [Setting up coding intelligence](https://developer.apple.com/documentation/Xcode/setting-up-coding-intelligence)
- Apple — [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- ACP — [Protocol overview](https://agentclientprotocol.com/protocol/v1/overview)
- ACP — [Session setup](https://agentclientprotocol.com/protocol/v1/session-setup)
- ACP — [Tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls)
- ACP — [Transports](https://agentclientprotocol.com/protocol/v1/transports)
- MCP — [Specification](https://modelcontextprotocol.io/specification)

## Sequenza operativa per Luna

1. Leggere `AGENTS.md`, questo piano e lo stato Git corrente.
2. Usare l'incarico dell'utente per determinare le slice autorizzate.
3. Cominciare dalla verifica dei contratti: nessun catalogo Xcode inventato.
4. Implementare incrementi piccoli con test pertinenti e commenti sugli invarianti.
5. Registrare per ogni slice cosa funziona, cosa è stato verificato realmente e
   cosa richiede ancora una sessione interattiva.
6. Considerare conclusa l'integrazione solo dopo i due percorsi di accettazione:
   TurboCode che usa Xcode via MCP e Xcode che ospita TurboCode via ACP.
