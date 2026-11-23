# RAMBar — RAM + WindowServer na menubar

Ícone estático na menubar. **Zero timer, zero polling, zero rede.**
Só lê o kernel (e o log do wsmon) na hora do clique e volta a dormir.

## Escopo

Clique mostra (pt-BR, GB base 1024³ igual à Apple):

- Memória Total
- Em Uso (abs + %)
- Disponível (= total − usada, inclui cache liberável)
- Swap Usado
- **WindowServer** (valor + há quanto tempo foi medido)
- Abrir log do wsmon
- Sair

O ícone é estático e monocromático. Sem timer, sem polling, sem rede.

## De onde vem o número do WindowServer

Do log do monitor já existente, `~/Library/Logs/wsmon.log`
(LaunchAgent `com.voce.wsmon`, linha `2026-11-23 14:54,489`):

- **não** roda `top` (que custa ~0,2 s de CPU e um processo por chamada)
- **não** precisa de root (`footprint` no WindowServer exige)
- é só ler a última linha de um arquivo pequeno, **no clique**

O valor aparece colorido: neutro `< 900 MB`, laranja `≥ 900 MB`,
vermelho `≥ 1.2 GB`. A idade entre parênteses mostra se o dado
está fresco (o wsmon grava a cada 30 min). Se o log não existir,
mostra "sem dados".

## Arquivos

- `main.swift` — app inteiro (~150 linhas, AppKit puro, sem deps)
- `build.sh` — compila universal (arm64+x86_64 via lipo), monta `.app`, ad-hoc sign
- `install.sh` — copia p/ `~/Applications` e abre (login via Settings > Login Items)
- `uninstall.sh` — remove tudo (idempotente)

## Fórmula (igual Activity Monitor)

```
Used = (internal − purgeable) + wired + compressor   [host_statistics64]
Disponível = total − used                             [hw.memsize − used]
```

`speculative` já está em `free` (não somar). `vm_kernel_page_size`
(16384 ARM). `UInt64` sempre. Swap via `vm.swapusage` só no clique.

## Build / instala / remove

```sh
./build.sh            # gera RAMBar.app universal
./build.sh --run      # build + abre
./install.sh          # copia p/ ~/Applications e abre
./uninstall.sh        # remove tudo
```

Login automático: System Settings > General > Login Items > `+` > RAMBar.

Requer: macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

## Custo real esperado (honesto, não "zero absoluto")

- `0.0%` CPU, **0 wakeups** (sem timer; só acorda no clique)
- `phys_footprint` ~22MB (piso Swift runtime + AppKit, inevitável)

Medir (após 5min warmup):

```sh
sudo powermetrics --samplers tasks -i 5000 -n 20 --show-process-energy
top -stats pid,command,cpu,power -pid "$(pgrep -x RAMBar)"
ps -o pid,rss,vsz,etime -p "$(pgrep -x RAMBar)"
pmset -g assertions   # provar sem power assertion
```

Conferir número: `vm_stat` + Activity Monitor.
Auditar: `grep -Ein 'socket|URLSession|http|curl|exec|spawn' main.swift` deve dar 0;
`lsof -i -p "$(pgrep -x RAMBar)"` deve dar 0.

## Distribuição

Build local não tem quarentena → roda. ZIP/DMG baixado tem
`com.apple.quarantine` → para terceiros exige Developer ID + notarização:

```sh
codesign --verify --deep --strict --verbose=2 RAMBar.app
spctl --assess --type execute -vv RAMBar.app
```

Sem assinatura paga: distribua **source + `./build.sh`**.
