# Glassify — дорожная карта

База — Vitrine (GPL-3.0 форк spoti.pw 0.21.1), Spotify 9.1.90. Цель — всё из Chroma 0.50 / 0.51-beta.1 без Plus.

## Правила

- Код пишется свой или берётся из GPL-источников (Vitrine, spoti.pw ≤ коммита `c790445`). Исходники spoti.pw после
  смены лицензии (`f44abdf`, PolyForm Strict) и бинарники Chroma — только справочник поведения.
- Состояние аккаунта Spotify не подменяется (Spoof Premium удалён). Блокировка рекламы остаётся.
- Внутренние пути хранилища и ключи Keychain Vitrine сохранены — так проще подтягивать обновления из `vitrine/main`.

## Сделано поверх Vitrine

- [x] Ребрендинг: `SG_NAME` (Glassify), своя иконка (`icons/Glassify*.png`, исходник `icons/source/glassify.html`),
      имя на домашнем экране в `make release`, `SG_REPO` для проверки обновлений (MVTTSUN/glassify; пусто = выкл.).
- [x] Удалён Spoof Premium (`Premium.m`, `Crossfade.x`, `RadioModes`, ветка в `AdNetwork.x`).
- [x] `scripts/extract-flags.py` читает бинарник без локальных символов (EeveeDecrypter 9.1.90): 2361/2523 флагов с типом.
- [x] Скачивание одной песни: ⋯ плеера → Download Song (`Shared/TrackDownload`, офлайн самого Spotify).

## Добавлено из 0.51 (собирается, на устройстве не проверено)

- [x] AutoMix — `Shared/AutoMix`: собственные Crossfade/Automix Spotify на плейлистах, альбомах, радио; Beat-matched там,
      где сервер Spotify разрешает сведение, иначе кроссфейд 1–12 с; на подкастах — прежние настройки.
- [x] Visualizer — 6 Metal-шейдеров (Aurora, Pulse Ring, Liquid, Starfield, Glow Wave, Prism) + Hills, свои шейдеры
      с редактором, Intensity, урезанный режим в Low Power, подменю Visualizer Style в ⋯.
- [x] Акцент «Follow the cover» в обоих видах, Plain checkmark в нативном виде, 31 семейство Google Fonts для загрузки.
- [x] Громкость под контролами управляет и Connect-устройством; DJ открывается в редизайн-плеере (Switch It Up в ⋯).
- [x] Top picks на Home — крупная карусель первой полки; шорткаты на стекле с оттенком обложки.

## Проверка на устройстве (не начата)

- Запуск на 9.1.90, морф открытия плеера (`CompactOverlayTransition` вместо `SPTBarOverlayPresentationTransition`).
- Download Song: принимает ли ядро одиночный трек; иначе — служебный плейлист.
- Всё из раздела «Добавлено из 0.51»: шаги проверки — в docs/tweaks.md и в логе `make log`.
