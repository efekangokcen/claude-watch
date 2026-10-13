# claude-watch

Apple Watch'tan Claude Code oturumlarını takip et, soru sor, izin ve soruları saatten cevapla, bitince bildirim al. Ücretsiz Apple ID ile çalışır, ücretli geliştirici hesabı gerekmez.

*Monitor Claude Code sessions from your Apple Watch: live status, transcripts, ask questions, answer permission prompts and finished-task replies from your wrist, push notifications via ntfy. Works with a free Apple ID.*

İki parça:

1. **bridge/** – Mac'te çalışan köprü servisi (Bun). Oturum durumunu, sohbet geçmişini ve soru göndermeyi yerel ağda bir HTTP + WebSocket API olarak açar.
2. **watch/** – watchOS uygulaması (SwiftUI, watchOS 11+, bağımsız çalışır). Oturum listesi, sohbet görünümü, dikte ile soru sorma, Bonjour ile Mac'i otomatik bulma.

## Köprü nasıl çalışır

Claude Code zaten her şeyi diske yazıyor, köprü sadece bunları okur:

| Kaynak | Ne verir |
|---|---|
| `~/.claude/sessions/<pid>.json` | Açık oturumlar: isim, cwd, `busy` / `idle` durumu |
| `~/.claude/projects/<cwd>/<sessionId>.jsonl` | Sohbet geçmişi (artımlı okunur, büyük dosyalar sorun değil) |
| Claude Code hook'ları → `POST /hook` | Anlık olaylar: prompt gönderildi, bitti, onay bekliyor |
| `claude -p --resume <id>` | Saatten gelen soruyu bir oturumun devamı olarak çalıştırır |

Masaüstü uygulamasında **o an açık** olan bir sohbete dışarıdan mesaj enjekte edilemiyor (resmi API yok). Köprü böyle bir oturum için `409 session_live` döner; `force: true` ile aynı sohbetin ayrı bir devamı başlatılabilir, kapalı oturumlar için doğrudan çalışır.

## Saatten cevap verme ve bildirimler

Köprü, Mac'te 90 sn klavye/fare hareketi yoksa seni **uzakta** sayar (`away.afterSec`; saatten "Mac'ten uzaktayım" ile zorlanabilir). Uzaktayken:

| Olay | Ne olur |
|---|---|
| Claude izin istiyor (`PermissionRequest` hook) | Hook bekletilir, saatte **İzin ver / Reddet** kartı çıkar, telefona ntfy bildirimi gider (butonlu). Cevap hook'a döner, masaüstü oturumu devam eder. |
| Claude seçenekli soru soruyor (`PreToolUse` → AskUserQuestion) | Seçenekler saate düşer. Seçimin, aracın ret gerekçesi olarak Claude'a iletilir ve o cevapla devam eder. |
| İş bitti (`Stop` hook) | 60 sn **cevap penceresi** (`hold.replyWindowSec`). Saatten hazır cevap veya dikteyle yazarsan Claude aynı sohbette devam eder. |
| Claude girdi bekliyor (`Notification`) | Telefona bildirim. |

Mac'e dönersen (boşta süresi sıfırlanır) bekleyen hook anında bırakılır ve masaüstü diyaloğu normal çıkar. Mac başındayken hiçbir hook bekletilmez, sadece "bitti" bildirimi gider (`ntfy.onlyWhenAway: true` ise o da gitmez).

**ntfy kurulumu:** App Store'dan **ntfy** uygulamasını iPhone'a kur, köprü logundaki konuya abone ol (`~/.claude-watch/config.json` → `ntfy.topic`, saatte Ayarlar'da da yazar). iPhone bildirimleri Apple Watch'a yansıtır. Test: `POST /api/test-push`. Konu adı rastgele ve gizli; istersen kendi ntfy sunucunu `ntfy.url` ile verebilirsin.

## Kurulum

```bash
cd bridge
bun run start            # http://0.0.0.0:7788
bun run install-hooks    # ~/.claude/settings.json'a hook ekler (yedek alır), geri almak: bun run uninstall-hooks
./scripts/install-launchd.sh   # girişte otomatik başlat + çökerse yeniden başlat (kaldır: --remove)
```

İlk çalıştırmada `~/.claude-watch/config.json` oluşur. Token oradadır; saat uygulaması bunu kullanır.

```jsonc
{
  "port": 7788,
  "host": "0.0.0.0",
  "token": "…",
  "claudeBin": "/Users/you/.bun/bin/claude",
  "allowedTools": [],          // saatten gelen sorular için otomatik izinli araçlar, örn. ["Read","Grep","Glob"]
  "askModel": "sonnet",        // saatten gelen sorularda kullanılan model (maliyet için); null = varsayılan
  "recentLimit": 40,
  "maxMessagesPerSession": 400,
  "runTimeoutMs": 600000
}
```

Claude CLI yoksa: `bun install -g @anthropic-ai/claude-code` (sorular için gerekli, izleme için değil).

## API

Tüm uçlar `Authorization: Bearer <token>` ister (`/api/health` ve loopback'ten gelen `/hook` hariç). WebSocket için `?token=`.

| Uç | Açıklama |
|---|---|
| `GET /api/health` | `{ok, claude}` |
| `GET /api/sessions?limit=40` | Açık oturumlar önce, sonra en son dokunulanlar. Her biri `status.state`: `needs_input` / `busy` / `idle` / `ended` |
| `GET /api/sessions/:id?limit=50&before=<msgId>` | Oturum özeti + son mesajlar (`role`: user / assistant, `tools`: kullanılan araç adları) |
| `POST /api/sessions/:id/ask {text, force?}` | Oturuma soru sor (`claude -p --resume`). Açık oturumda `409` |
| `POST /api/ask {text, cwd?}` | Yeni sohbet başlat |
| `GET /api/runs/:runId`, `POST /api/runs/:runId/cancel` | Çalışan soruyu izle / iptal et |
| `POST /hook` | Claude Code hook payload'ı (loopback) |
| `WS /ws` | Olaylar: `snapshot`, `session.update`, `session.removed`, `hook`, `notify`, `run.*` |

## Saat uygulaması

```bash
open watch/ClaudeWatch.xcodeproj
```

- Xcode'da bir kez **Signing & Capabilities → Team** seç (ücretsiz Apple ID yeter). Ücretsiz hesapta imza 7 günde bir düşer: iPhone'u takıp `watch/scripts/deploy.sh` çalıştır (veya Xcode'da Run). Ayarlar ve eşleştirme silinmez. Köprü 6. günde ntfy ile hatırlatır.
- Siri: "Claude Watch ile Claude'a sor" kısayolu yeni bir sohbet açıp cevabı okur.
- Hedef olarak iPhone'a bağlı Apple Watch'ı ya da bir watchOS simülatörünü seç, Run.
- İlk açılışta uygulama Bonjour ile köprüyü bulur; `bun run start` çıktısındaki 6 haneli **pair code**'u gir. Token saate kaydedilir.
- Köprü bulunamazsa "Elle adres" ile `IP:7788` yazılabilir.

Komut satırından derleme (imzasız, sadece kontrol):

```bash
xcodebuild build -project watch/ClaudeWatch.xcodeproj -scheme ClaudeWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO
```

Simülatörde çalıştırma:

```bash
xcodebuild build -project watch/ClaudeWatch.xcodeproj -scheme ClaudeWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/cw-dd
xcrun simctl install booted /tmp/cw-dd/Build/Products/Debug-watchsimulator/ClaudeWatch.app
xcrun simctl launch booted com.efekan.claudewatch
```

Bildirimler: uygulama açıkken olaylar titreşim + yerel bildirim olarak gelir; uygulama kapalıyken ntfy üzerinden telefona gider ve saate yansır (yukarıdaki bölüm).

## Durum

| Parça | Test |
|---|---|
| Köprü: oturum listesi, sohbet okuma, soru sorma, `--resume` devamı | Gerçek Claude Code oturumlarıyla uçtan uca doğrulandı |
| Köprü: izin / soru / cevap penceresi hook'ları, Mac'e dönünce bırakma | Doğrulandı |
| ntfy bildirimi | Doğrulandı |
| Saat uygulaması | watchOS 27 simülatöründe (Series 10 46mm) doğrulandı: eşleştirme, liste, sohbet, soru, izin kartı |
| Gerçek Apple Watch | Henüz denenmedi |

Gereksinimler: macOS + Xcode 26 veya üzeri, [Bun](https://bun.sh), Claude Code (`claude` CLI girişli), watchOS 11+ bir Apple Watch, iPhone'da ntfy uygulaması (bildirim için).

## Dış erişim

Yerel ağda LAN IP yeter. Dışarıdan: Mac'e Tailscale kur, saatte Tailscale IP'sini kullan (watchOS Tailscale'i iPhone üzerinden değil doğrudan desteklemez; en kolayı Tailscale Serve/Funnel ile HTTPS vermek). Portu doğrudan internete açma.

## Lisans

MIT. Bkz. [LICENSE](LICENSE).
