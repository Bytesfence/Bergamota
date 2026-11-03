#!/bin/bash
# Final Turnip deploy from stable stock system (SSH solid, no race).
# Ladder: dylibs -> flip hooked-bb WITH kill switches -> verify stable ->
#         switches off -> GPU verdict. Revert = flip stock (staged).
set -u
SSH="ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.7.2"
ART=/tmp/opencode/art4/out-metal
B=/usr/local/lib/bgmtl
T=/private/var/tmp
md5r() { $SSH "cat $1" 2>/dev/null | md5sum | cut -d' ' -f1; }

echo "== 0. sanity: backboardd is stock, volume writable"
[ "$(md5r /usr/libexec/backboardd)" = 602cc7f718fbac48924e5ebfcf59d44d ] || { echo "backboardd NOT stock - ABORT"; exit 1; }
$SSH "touch $T/bbflip.ok && rm $T/bbflip.ok" || { echo "volume NOT writable - ABORT"; exit 1; }
echo "   ok"

echo "== 1. stage revert net (stock bb + flipper) + plant kill switches"
$SSH "cat > $T/bb.stock" < /tmp/opencode/bb.stock
$SSH "cat > $T/bb.hooked" < /tmp/opencode/bb.hooked
$SSH "cat > $T/bbflip.sh" <<'EOS'
#!/bin/sh
case "$1" in
  stock) SRC=/private/var/tmp/bb.stock ;;
  new)   SRC=/private/var/tmp/bb.hooked ;;
  *) echo "usage: bbflip.sh stock|new"; exit 1 ;;
esac
cat "$SRC" > /usr/libexec/backboardd.tmp && chmod 755 /usr/libexec/backboardd.tmp \
  && mv -f /usr/libexec/backboardd.tmp /usr/libexec/backboardd && sync
echo "flipped to $1"
EOS
$SSH "chmod 755 $T/bbflip.sh; touch $T/bgmtl-bb.off $T/bgmtl.off; sync"
echo "   staged + switches ON"

echo "== 2. retire old stack + push new dylibs"
$SSH "cd $B && mv bgmtl-inject.dylib bgmtl-inject.dylib.old 2>/dev/null; mv libdrm.2.dylib libdrm.2.dylib.old 2>/dev/null; mv libbgair.dylib libbgair.dylib.bad 2>/dev/null; true"
for f in bgmtl-inject.dylib libchlorophyll.dylib libdrm.2.dylib; do
  echo "   pushing $f ($(stat -c%s $ART/$f) B)"
  $SSH "cat > $B/$f" < "$ART/$f"
done
$SSH "chmod 755 $B/*.dylib; sync"
for pair in "bgmtl-inject.dylib d116deb01e883f0bf17665e9a0d6f15e" \
            "libchlorophyll.dylib 0c01b0d7dd257c8812a08d1c207c848f" \
            "libdrm.2.dylib 97450a551831b045db309da75dadfa28"; do
  set -- $pair
  got=$(md5r $B/$1)
  [ "$got" = "$2" ] && echo "   OK  $1" || { echo "   MD5 FAIL $1 ($got) - ABORT"; exit 1; }
done

echo "== 3. flip backboardd -> hooked (switches ON: hook loads, GPU skipped)"
$SSH "$T/bbflip.sh new"
$SSH 'set -- $(ps -A | grep "[b]ackboardd"); kill -9 $1' && echo "   killed backboardd"

echo "== 4. stability watch (12s, switched-off GPU)"
LAST=""; GOOD=0
for j in $(seq 1 12); do
  P=$($SSH 'ps -A | grep "[b]ackboardd"' 2>/dev/null | head -1 | tr -s " " | cut -d" " -f1)
  if [ -n "$P" ] && [ "$P" = "$LAST" ]; then GOOD=$((GOOD+1)); else GOOD=0; LAST="$P"; fi
  [ $GOOD -ge 8 ] && break
  sleep 1
done
if [ $GOOD -lt 8 ]; then
  echo "   NOT STABLE with switches on - reverting to stock"
  $SSH "$T/bbflip.sh stock" || echo "   !! MANUAL REVERT NEEDED (bbflip.sh stock)"
  exit 1
fi
echo "   STABLE: hooked bb + inject loaded, pid=$LAST, GPU skipped"

echo "== 5. THE MOMENT: switches OFF -> kill -> Turnip/chlorophyll GPU engages"
$SSH "rm -f $T/bgmtl-bb.off $T/bgmtl.off; sync"
$SSH 'set -- $(ps -A | grep "[b]ackboardd"); kill -9 $1'
sleep 3
LAST=""; GOOD=0
for j in $(seq 1 15); do
  P=$($SSH 'ps -A | grep "[b]ackboardd"' 2>/dev/null | head -1 | tr -s " " | cut -d" " -f1)
  if [ -n "$P" ] && [ "$P" = "$LAST" ]; then GOOD=$((GOOD+1)); else GOOD=0; LAST="$P"; fi
  [ $GOOD -ge 10 ] && break
  sleep 1
done
echo "== 6. bgmtl.log since GPU engage:"
$SSH "tail -15 $T/bgmtl.log" 2>/dev/null
if [ $GOOD -ge 10 ]; then
  echo ""
  echo "================ GPU STACK LIVE (pid=$LAST, 10s stable) ==============="
  echo "SWIPE TEST NOW - fluid = Turnip compositing; laggy = software fallback"
  exit 0
fi
echo ""
echo "!! NOT STABLE with GPU on - flipping back to stock"
$SSH "$T/bbflip.sh stock; touch $T/bgmtl-bb.off $T/bgmtl.off; sync" && echo "reverted + switches on"
exit 1
