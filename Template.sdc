derive_pll_clocks
derive_clock_uncertainty

# core specific constraints — DJ Boy (fork da NightSlashers, tenuto solo il generico)

# ============================================================
# OSD HDMI (framework sys/osd.v): gp_outr (strobe HPS, dominio h2f) -> osd|bcnt (blanking
# counter dell'OSD, dominio video). Crossing HPS->OSD di CONFIG (non timing-critico).
set_false_path -from [get_registers {*gp_outr*}] -to [get_registers {*_osd|bcnt*}]

# CONFIG/STATUS HPS -> core (async, statici durante il gioco). Cambiano solo quando
# l'utente tocca l'OSD: crossing async, NON path runtime.
set_false_path -from [get_registers {*hps_io|status*}]
set_false_path -from [get_registers {*gp_outr*}] -to [get_registers {*cfg_custom*}]

# FALSE_PATH dal reset globale: reset_hold_cnt pilota SOLO `wire reset`, quasi-statico
# (decrementa al boot, poi 0 per sempre). Nessun requisito setup single-cycle.
set_false_path -from [get_registers {*reset_hold_cnt[*]}]

# ============================================================
# SAVESTATE (memory_stream): lo stream save/load avanza solo durante save/restore
# (gated, lento), NON durante il gioco. Multicycle generoso.
set_multicycle_path -setup -from [get_registers {*u_save_state|*}] 8
set_multicycle_path -hold  -from [get_registers {*u_save_state|*}] 7
set_multicycle_path -setup -from [get_registers {*memory_stream|*}] 8
set_multicycle_path -hold  -from [get_registers {*memory_stream|*}] 7

# LOAD SAVESTATE adaptor->chip (tv80/jt6295): il lean adaptor alza bits_wr a T+2
# rispetto a word_wr/word_idx (sorgenti del mux RMW stabili 3 periodi alla cattura)
# -> MC 3/2 VERO PER COSTRUZIONE.
set_multicycle_path -setup -from [get_registers {*_ss_adaptor|word_wr* *_ss_adaptor|word_idx*}] 3
set_multicycle_path -hold  -from [get_registers {*_ss_adaptor|word_wr* *_ss_adaptor|word_idx*}] 2

# ============================================================
# MULTICYCLE CPU/AUDIO RIMOSSI 2026-07-25 — sospetti del boot rotto.
# I blocchi `-from X -to X` a coperta su tutta l'istanza (Z80 x3, BEAST) e il
# `-to *jt12_pg*` includevano anche i path in cui launch/latch NON sono entrambi
# cen-gated: su quelli l'-hold 7 e' FALSO e autorizza il fitter a skewarli ->
# boot instabile (pattern verificato Act-Fancer: MC falso = core non parte, STA
# verde bugiardo). Il timing negativo che ne risulta NON e' un fault (regola
# utente: timing negativo != core rotto). Se servira' chiudere il timing, andranno
# dichiarati MC MIRATI ai SOLI registri cen-gated verificati, MAI a coperta, MAI
# -hold su path con endpoint a clk pieno.
# Restano solo i multicycle savestate (sopra), veri per costruzione.
