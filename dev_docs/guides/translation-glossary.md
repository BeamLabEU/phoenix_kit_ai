# Translation glossary (en → et → ru)

The terms the `et` and `ru` catalogues (`priv/gettext/`) use, so a new string
reads like the rest. Agreed in the 2026-11-08 review
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
