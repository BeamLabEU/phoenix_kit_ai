# Translation glossary

The terms the catalogues (`priv/gettext/`) use, so a new string reads like
the rest: Estonian and Russian in the table below, then one section per
language added on 2026-11-08 (German, Spanish, French, Italian, Chinese). Agreed in the 2026-11-08 review
(`dev_docs/reviews/2026-11-08-week-review-and-hardening.md`), when 191
entries were brought in line with it. Add a row when a new term comes in.

Register: **et** — 2nd person singular imperative and "sina" (Vali, Sisesta, Sul pole õigust), as in
most of the catalogue; **ru** — formal «вы» imperative in sentences (Выберите, Введите), infinitive on
buttons (Создать, Сохранить). Busy labels ("Saving…") are nouns in both: Salvestamine… / Сохранение….
Task descriptions (`ai_tasks/0` purpose) are 3rd person: Tõlgib… / Переводит….

| English | Estonian | Russian | Notes |
|---|---|---|---|
| AI (module / tab name) | AI | AI | proper name of the module; keep |
| AI (in prose) | AI- (compound: AI-ülesanne, AI-päring, AI-moodul) | ИИ (задача ИИ, запросы к ИИ, модуль ИИ) | not "AI" in ru prose |
| endpoint | lõpp-punkt (AI lõpp-punkt) | конечная точка | never "otspunkt" / "эндпоинт" |
| prompt | prompt (promptmall = prompt template) | промпт (шаблон промпта) | never "viip"; ru never "запрос" for prompt |
| system prompt | süsteemne prompt | системный промпт | |
| request (HTTP / usage row) | päring | запрос | |
| call (one verb invocation) | päring | вызов | et has one word for both |
| usage | kasutus | использование | tab "Kasutus" / «Использование» |
| journal (usage log) | logi; entry = logikirje; row = logirida | журнал; entry = запись журнала | |
| content (of an entry) | sisu | содержимое | clearing = eemaldamine / очистка (not вычистка) |
| retention | säilitamine; period = säilitustähtaeg (tähtaeg) | хранение; period = срок хранения | |
| keep forever | hoia alatiseks | хранить всегда | |
| cleanup (nightly / manual) | puhastus (öine / käsitsi) | очистка (ночная / ручная) | |
| spending cap | kulupiir | лимит расходов | not "kulupiirang" / "kululimiit" |
| budget | eelarve | бюджет | |
| limit (task / personal) | piir (päevane, igakuine …) | лимит (дневной, месячный …) | et never "limiit"/"piirang"; "kuine" is not a word |
| forgive / forgiven limit | anna andeks / andeks antud piir | простить / прощённый лимит | |
| task (AI task) | ülesanne (AI-ülesanne) | задача (задача ИИ) | |
| guard (task guard) | valve (AI-ülesannete valve) | охрана (охрана задач ИИ) | consistent today; "контроль задач ИИ" would read more naturally in ru, but changing it means ~45 entries |
| guard event | valve sündmus | событие охраны задач | |
| flag (off-purpose) | märge; eesmärgiväline märge | отметка; отметка «не по назначению» | not "märgis", "флаг", "нецелевое использование" |
| block / lift a block | blokeering / eemalda blokeering | блокировка / снять блокировку | |
| watcher | jälgija | наблюдатель | |
| model | mudel | модель | |
| provider | teenusepakkuja | провайдер | et "pakkuja" only for OpenRouter's upstream providers of a model |
| operator (catalogue owner) | operaator | оператор | |
| integration | integratsioon | интеграция | |
| connection (picker) | ühendus | подключение | |
| capability | võimekus / võimalus | возможность | |
| verified / not verified | kontrollitud / kontrollimata | проверено / не проверено | |
| catalogue | kataloog | каталог | |
| token | token (sisend-/väljundtoken) | токен (входные/выходные токены) | never "märk" (= character) |
| context (window) | kontekst | контекст | |
| latency | latentsus | задержка | not "viivitus" |
| cost / price | maksumus / hind | стоимость / цена | |
| per 1M tokens | 1M tokeni kohta | за 1 млн токенов | |
| embedding | vektoresitus | эмбеддинг | not "embedding", "manustamine" |
| image generation | piltide genereerimine | генерация изображений | not "pildigeneratsioon", "piltide loomine" |
| image | pilt | изображение | not "картинка" in labels |
| aspect ratio / resolution | kuvasuhe / eraldusvõime | соотношение сторон / разрешение | |
| portrait / landscape | püstine / rõhtne | вертикальный / горизонтальный | not "портрет" / "альбом" |
| reasoning / thinking | arutluskäik / mõtlemine | рассуждения | not "размышление" |
| effort level | pingutuse tase | уровень усилий | |
| text-to-speech | kõnesüntees | синтез речи | |
| speak (TTS button) | loe ette | озвучить | not "räägi" |
| transcription / speech to text | kõne üleskirjutamine | расшифровка речи | |
| dictation / dictate | dikteerimine / dikteeri | диктовка / надиктовать | |
| recording | salvestis | запись | |
| Playground | Liivakast | Песочница | also inside sentences |
| Settings → Integrations | „Seaded → Integratsioonid“ (jaotises …) | «Настройки → Интеграции» (в разделе …) | |
| Owner | omanik | владелец | |
| Speech to text (card) | Kõne tekstiks | Расшифровка речи | the Playground card |
| speech-to-text API / model | kõnetuvastuse API / kõnetuvastusmudel | API / модель распознавания речи | `/audio/transcriptions` |
| record (button) | lindista | записать | not "salvesta" (= save) |
| write down (a recording) | kirjuta üles | расшифровать | busy: Üleskirjutamine… / Расшифровка… |

## German (de)

Register: "Sie" in sentences; buttons are infinitives (Speichern, Abbrechen); busy labels "Wird …t…" (Wird gespeichert…, Wird geladen…); task descriptions 3rd person (Übersetzt…, Schreibt…).

| English | German |
|---|---|
| AI (tab name and in prose) | KI (KI-Endpunkt, KI-Aufgabe, KI-Modul) |
| endpoint | Endpunkt |
| prompt / prompt template | Prompt / Prompt-Vorlage |
| system prompt | System-Prompt |
| request (usage row / API request) | Anfrage |
| call (one verb invocation) | Aufruf |
| usage (tab) | Nutzung |
| journal | Protokoll |
| journal entry / row | Protokolleintrag |
| content (of an entry) / clear | Inhalt / leeren, entfernen |
| retention / retention period | Aufbewahrung / Aufbewahrungsdauer (kurz: Dauer) |
| keep forever / kept forever | Dauerhaft aufbewahren / Dauerhaft aufbewahrt |
| cleanup (nightly / manual) | Bereinigung (nächtliche / manuelle) |
| cleanup boundary | Bereinigungsgrenze |
| spending cap | Ausgabenlimit |
| budget | Budget |
| limit (task / personal) | Limit (persönliches Limit) |
| daily / monthly spending limit (task money limit) | Tageslimit / Monatslimit für Kosten (Kostenlimit) |
| daily request / token limit | Tageslimit für Anfragen / für Token |
| money (limit unit) | Kosten |
| forgive / limit forgiven | Erlassen / Limit erlassen |
| task (AI task) | KI-Aufgabe / Aufgabe |
| guard (task guard) | Aufgabenwache (KI-Aufgabenwache) |
| guard events | Ereignisse der Aufgabenwache |
| flag / off-purpose | Markierung / zweckfremd (Markierungen „zweckfremd“) |
| block / lift a block | Sperre, sperren / Sperre aufheben |
| watcher | Beobachter |
| Owner | Eigentümer (as in PhoenixKit core) |
| model | Modell |
| provider | Anbieter |
| operator (catalogue owner) | Betreiber |
| integration / connection | Integration / Verbindung |
| credentials | Anmeldedaten (as in core) |
| capability / declare (on endpoint) | Fähigkeit / angeben |
| declare (a task, by a module) | deklarieren |
| verified / not verified | geprüft / nicht geprüft |
| catalogue | Katalog |
| token | Token (pl. Token) |
| latency | Latenz |
| cost / price / list price | Kosten / Preis / Listenpreis |
| per 1M tokens | pro 1 Mio. Token |
| embedding | Embedding |
| image generation | Bildgenerierung |
| aspect ratio / resolution | Seitenverhältnis / Auflösung |
| portrait / landscape / square | Hochformat / Querformat / quadratisch |
| reasoning / thinking | Denkprozess / Denken |
| effort level | Aufwandsstufe |
| tools (capability) | Werkzeuge |
| text-to-speech / speak | Sprachsynthese (TTS) / Vorlesen |
| speech to text | Sprache zu Text (Sprache-zu-Text-API, -Modell) |
| transcription / write down | Transkription / transkribieren |
| dictation / dictate | Diktieren |
| recording / record | Aufnahme / Aufnehmen |
| Playground | Playground (also inside sentences) |
| batch / fallback models | Batch / Fallback-Modelle |
| Settings → Integrations | „Einstellungen → Integrationen“ |

## Spanish (es)

Register: formal "usted" in sentences (Seleccione, Introduzca, ¿Seguro que quiere…?); buttons are
infinitives (Guardar, Cancelar, Eliminar); busy labels are gerunds (Guardando…, Transcribiendo…).
Quotes: «». Example prompts addressed to the model use "tú" (Traduce…, Eres…), as in the et/ru catalogues.

| English | Spanish |
|---|---|
| AI (tab and in prose) | IA (tarea de IA, módulo de IA) |
| endpoint | endpoint (masc.: el endpoint, los endpoints) |
| prompt / prompt template | prompt (masc.) / plantilla de prompt |
| system prompt | prompt de sistema |
| request (usage row, HTTP) | solicitud |
| call (one verb invocation) | llamada |
| usage / Usage tab | uso / Uso |
| journal | registro |
| journal entry / row | entrada del registro |
| content (of an entry) | contenido (remove → eliminar; clear → borrar) |
| retention / retention period | conservación / periodo de conservación |
| keep forever | Conservar siempre |
| cleanup (nightly / manual) | limpieza (nocturna / manual) |
| cleanup boundary | fecha de corte |
| background job (Oban) | trabajo (en segundo plano) |
| spending cap | tope de gasto |
| budget | presupuesto |
| limit (task / personal) | límite (diario, mensual, personal) |
| forgive / forgiven limit | Perdonar / límite perdonado |
| task (AI task) | tarea de IA |
| guard (task guard) | control de tareas (de IA) |
| guard event | evento del control de tareas |
| flag (off-purpose) | marca; marca «fuera de la finalidad» (in prose: ajeno a su finalidad) |
| block / lift a block | bloqueo / levantar el bloqueo |
| watcher | observador |
| Owner | propietario |
| model / provider / operator | modelo / proveedor / operador |
| integration / connection | integración / conexión |
| Settings → Integrations | «Configuración → Integraciones» |
| settings (of a provider, endpoint) | ajustes |
| capability / declared | capacidad / declarada |
| verified / not verified | verificado / sin verificar |
| catalogue | catálogo |
| token (input / output) | token (tokens de entrada / de salida) |
| per 1M tokens | por 1 M de tokens |
| latency | latencia |
| cost / price / list price | coste / precio / precio de lista |
| embedding | embedding (modelo de embeddings) |
| image generation | generación de imágenes |
| aspect ratio / resolution | relación de aspecto / resolución |
| portrait / landscape / square | vertical / horizontal / cuadrado |
| reasoning / thinking | razonamiento |
| effort level | nivel de esfuerzo |
| text-to-speech | síntesis de voz |
| speak (TTS button) | Leer en voz alta |
| speech to text (card) / speech-to-text API | Voz a texto / API de voz a texto |
| write down (a recording) | Transcribir (busy: Transcribiendo…) |
| dictation / dictate | dictado / Dictar |
| recording / record (button) | grabación / Grabar |
| path (transcription route) | vía |
| Playground | Zona de pruebas (also inside sentences) |
| enabled / disabled | habilitado / deshabilitado (switched off → desactivado) |
| default | predeterminado |
| batch / item | lote / elemento |
| run (of a batch, cleanup) | ejecución |

## French (fr)

Register: "vous" in sentences ("Entrez…", "Êtes-vous sûr de vouloir supprimer… ?"), infinitives on buttons
("Enregistrer", "Annuler"), busy labels are nouns ("Enregistrement…", "Transcription…"). Task descriptions
are 3rd person ("Traduit…", "Transcrit…"). A no-break space goes before « : ; ? ! % » and inside « guillemets ».

| English | French |
|---|---|
| AI (tab / module name, prose) | IA (module IA, requêtes IA, tâche IA) |
| endpoint | point de terminaison (point de terminaison IA) |
| prompt / prompt template | prompt / modèle de prompt |
| system prompt | prompt système |
| request (usage row, HTTP) | requête |
| call (one verb invocation) | appel |
| usage | utilisation |
| journal / entry / row | journal / entrée du journal / ligne du journal |
| content (of an entry) | contenu (clearing it: vider le contenu) |
| retention / period | conservation / durée de conservation |
| keep forever / kept forever | conserver indéfiniment / conservé indéfiniment |
| cleanup (nightly / manual) | nettoyage (nocturne / manuel) |
| cleanup boundary | date limite de nettoyage |
| spending cap | plafond de dépenses |
| budget | budget |
| limit (task / personal) | limite (quotidienne, mensuelle ; limite personnelle) |
| spending limit (task) | limite de dépenses |
| forgive / limit forgiven | remettre à zéro / limite remise à zéro |
| task (AI task) | tâche (tâche IA) |
| guard (task guard) | contrôle des tâches (contrôle des tâches IA) |
| guard event | événement du contrôle des tâches |
| flag / off-purpose | signalement / hors sujet (sentences: « hors de son objet ») |
| block / lift a block | blocage / lever le blocage |
| watcher | observateur |
| Owner | propriétaire |
| model | modèle |
| provider | fournisseur |
| operator (catalogue owner) | opérateur |
| integration / connection | intégration / connexion |
| capability | capacité |
| verified / not verified | vérifié / non vérifié |
| catalogue | catalogue |
| list price (built-in table) | tarif public |
| token | jeton (jetons d'entrée / de sortie) |
| per 1M tokens | par million de jetons |
| context (window) | contexte |
| latency | latence |
| cost / price | coût / prix |
| embedding | embedding |
| image generation | génération d'images |
| aspect ratio / resolution | proportions / résolution |
| portrait / landscape / square | portrait / paysage / carré |
| reasoning / thinking | raisonnement / réflexion |
| effort level | niveau d'effort |
| text-to-speech / speak (button) | synthèse vocale / Lire à voix haute |
| speech to text (card) | Parole en texte |
| transcription / write down | transcription / Transcrire (busy: Transcription…) |
| speech-to-text API / model | API de transcription / modèle de transcription |
| dictation / dictate | dictée / Dicter |
| recording / record (button) | enregistrement / Enregistrer |
| Playground | Bac à sable (also inside sentences) |
| Settings → Integrations | « Paramètres → Intégrations » |
| permission | permission (Gérer le contrôle des tâches IA) |
| batch / item | lot / élément |
| e.g. | p. ex. |

## Italian (it)

Register: informal "tu" in sentences (Inserisci, Scegli, Vuoi davvero…?); buttons are imperatives
(Salva, Annulla, Elimina); busy labels are nouns (Salvataggio…, Conteggio…, Trascrizione…);
permission labels are infinitives (Gestire…, Vedere…); task descriptions are 3rd person (Traduce…).
Dates: `%{day} %{month} %{year}`, months lowercase; before a date in a sentence "il giorno / dal giorno /
anteriore al giorno %{date}" (avoids "dal 8" / "l'11" elision problems), or the date after a colon.

| English | Italian |
|---|---|
| AI (module / tab, in prose) | IA (endpoint IA, attività IA, richieste all'IA) |
| endpoint | endpoint (masc.: l'endpoint, gli endpoint) |
| prompt / prompt template | prompt (masc.) / template di prompt |
| system prompt | prompt di sistema |
| request (usage row / API) | richiesta |
| call (one verb invocation) | chiamata |
| usage / Usage tab | utilizzo / «Utilizzo» |
| journal / entry / row | registro / voce del registro / riga del registro |
| content (of an entry) / clearing | contenuto / rimozione (rimosso) |
| retention / retention period | conservazione / periodo di conservazione |
| keep forever / kept forever | conserva per sempre / conservato per sempre |
| cleanup (nightly / manual) | pulizia (notturna / manuale) |
| cleanup boundary | soglia della pulizia |
| run (of a job) / job | esecuzione / job |
| spending cap | tetto di spesa |
| budget | budget |
| limit (task / personal) | limite (giornaliero, mensile; limiti personali) |
| spending limit (task money limit) | limite di spesa |
| forgive / limit forgiven | condona / limite condonato |
| task (AI task) / Tasks tab | attività IA / «Attività» |
| guard (AI task guard) | vigilanza (vigilanza delle attività IA) |
| guard events | eventi di vigilanza |
| flag / off-purpose | segnalazione / fuori scopo |
| block / lift a block / blocked | blocco / rimuovi il blocco / bloccato |
| watcher | osservatore |
| Owner | proprietario (Proprietario as a role name) |
| model / provider / operator | modello / provider / operatore |
| integration / connection | integrazione / connessione (status: Collegato / Non collegato) |
| capability / declared | capacità / dichiarata |
| verified / not verified | verificato / non verificato |
| mark (a capability) | segnare (segnato a mano) |
| catalogue / list price | catalogo / prezzo di listino |
| token / input / output tokens | token / token di input / token di output |
| per 1M tokens | per 1M token |
| context (window) | contesto (finestra di contesto) |
| latency | latenza |
| cost / price | costo / prezzo |
| embedding | embedding |
| image generation / image | generazione di immagini / immagine |
| aspect ratio / resolution | proporzioni / risoluzione |
| portrait / landscape / square | verticale / orizzontale / quadrato |
| reasoning / thinking | ragionamento |
| effort level | livello di sforzo |
| text-to-speech / speak (button) | sintesi vocale / Leggi ad alta voce (busy: Lettura…) |
| voice / mood / speaker | voce / tono / speaker |
| speech to text (Playground card) | Voce in testo |
| transcription / write down (busy) | trascrizione / Trascrivi (Trascrizione…) |
| speech-to-text API / model | API di riconoscimento vocale / modello di riconoscimento vocale |
| dictation / dictate | dettatura / Detta |
| recording / record (button) | registrazione / Registra |
| path (chat or /audio/transcriptions) | percorso |
| Playground | Playground (also inside sentences: nel Playground) |
| Settings → Integrations | «Impostazioni → Integrazioni» |
| batch / item | batch / elemento |
| fallback models | modelli di riserva |
| refused | rifiutata |

## Chinese (zh)

Register: 您 in sentences, short verbs on buttons (保存, 取消, 删除), busy labels 正在…… as "正在保存…". Full-width punctuation in Chinese text; a space between Chinese and Latin words, numbers and placeholders.

| English | Chinese |
|---|---|
| AI (module / tab) | AI |
| endpoint | 端点 |
| prompt / prompt template | 提示词 / 提示词模板 |
| system prompt | 系统提示词 |
| request (usage row / API call) | 请求 |
| call (one verb invocation) | 调用 |
| usage (tab) | 用量 |
| journal | 日志 |
| journal entry / row | 日志条目 |
| content (of an entry) | 内容 |
| retention / retention period | 保留 / 保留期限 |
| keep forever / kept forever | 永久保留 |
| cleanup (nightly / manual) | 清理（夜间清理 / 手动清理） |
| cleanup boundary | 清理边界 |
| spending cap | 支出上限 |
| budget | 预算 |
| limit (task / personal) | 限额（每日 / 每月 / 个人限额） |
| spending limit (money limit of a task) | 支出限额 |
| forgive / forgiven limit | 豁免 / 已豁免的限额 |
| task (AI task) | AI 任务（tab: 任务） |
| task guard | 任务守卫（AI 任务守卫） |
| guard event | 任务守卫事件 |
| flag / off-purpose flag | 标记 / 偏离用途标记 |
| block / lift a block | 封禁 / 解除封禁 |
| watcher | 关注人 |
| Owner | 所有者 |
| model | 模型 |
| provider | 提供商 |
| operator (catalogue owner) | 运营方 |
| integration | 集成 |
| connection (picker) | 连接 |
| capability | 能力 |
| verified / not verified | 已验证 / 未验证 |
| catalogue | 目录 |
| list price (built-in) | 标价 |
| token | token |
| per 1M tokens | 每百万 token |
| context (window) | 上下文（窗口） |
| latency | 延迟 |
| cost / price | 费用 / 价格 |
| embedding | 嵌入 |
| image / image generation | 图像 / 图像生成 |
| aspect ratio / resolution | 宽高比 / 分辨率 |
| portrait / landscape / square | 竖向 / 横向 / 正方形 |
| reasoning / thinking | 推理 / 思考 |
| effort level | 推理强度 |
| text-to-speech | 语音合成 |
| speak (TTS button) | 朗读 |
| speech to text (card) | 语音转文字 |
| speech-to-text API / model | 语音识别 API / 语音识别模型 |
| transcribe / write down (a recording) | 转写（busy: 正在转写…） |
| dictation / dictate | 听写 |
| recording / record (button) | 录音 |
| Playground | 测试场 |
| Settings → Integrations | “设置 → 集成” |
| batch | 批处理 |
| fallback model | 备用模型 |
| run (a `run:` tag / cleanup run) | 运行 |
| job (Oban) | 作业 |
