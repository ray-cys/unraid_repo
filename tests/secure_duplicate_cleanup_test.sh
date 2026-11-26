#!/bin/bash
# Run on Hubble (native PHP); isolated temporary files only, no live APIs.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/secure-duplicate-fixture.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
awk '/^<\?php$/{capture=1} /^\/\/ MAIN$/{exit} capture{print}' "$repo/tools/secure_duplicate_cleanup.sh" >"$tmp/library.php"
cat >"$tmp/test.php" <<'PHP'
<?php
require $argv[1];$root=$argv[2];mkdir($root.'/ポルノ/keep',0777,true);mkdir($root.'/ポルノ/extra',0777,true);mkdir($root.'/プライベート/ポルノコレクション',0777,true);
function check($v,$why){if(!$v)throw new RuntimeException('Fixture failed: '.$why);}
function proof($p,$root){return fileState($p,$root)+['sha256'=>hash_file('sha256',$p)];}
function blocked($fn,$why){try{$fn();}catch(RuntimeException $e){return;}throw new RuntimeException('Expected protection: '.$why);}
$keep=$root.'/ポルノ/keep/ABC-123.mp4';$extra=$root.'/ポルノ/extra/ABC-123.mp4';file_put_contents($keep,'identical media');file_put_contents($extra,'identical media');
$k=proof($keep,$root);$d=proof($extra,$root);$r=applyVerifiedPair(['keep'=>$keep,'remove'=>$extra],$k,$d,$root);
check(file_exists($keep)&&!file_exists($extra)&&!is_dir(dirname($extra))&&$r['keeperStableAfter'],'exact duplicate and only empty directory removed');
mkdir(dirname($extra));file_put_contents($extra,'different media');$d=proof($extra,$root);blocked(fn()=>applyVerifiedPair(['keep'=>$keep,'remove'=>$extra],$k,$d,$root),'different content');check(file_exists($extra),'different encode retained');
file_put_contents($extra,'identical media');$d=proof($extra,$root);file_put_contents($keep,'changed keeper with new size');blocked(fn()=>applyVerifiedPair(['keep'=>$keep,'remove'=>$extra],$k,$d,$root),'changed keeper');check(file_exists($extra),'changed-keeper protection');
$x=$root.'/プライベート/ポルノコレクション/ABC-123.mp4';file_put_contents($x,'identical media');blocked(fn()=>fileState($x,$root),'excluded folder');check(file_exists($x),'excluded file unchanged');
$link=$root.'/ポルノ/link.mp4';symlink($keep,$link);blocked(fn()=>fileState($link,$root),'file symlink');
symlink(dirname($keep),$root.'/ポルノ/linkdir');blocked(fn()=>fileState($root.'/ポルノ/linkdir/ABC-123.mp4',$root),'parent symlink');
blocked(fn()=>fileState($root.'/ポルノ/../outside.mp4',$root),'traversal');
file_put_contents($keep,'stable media');$cache=[];$one=verifiedHash($keep,$root,$cache);$two=verifiedHash($keep,$root,$cache);check($one['sha256']===$two['sha256'],'cached full native hash reused');
blocked(fn()=>applyVerifiedPair(['keep'=>$keep,'remove'=>$keep],$one,$one,$root),'keeper never deleted');
// A nonempty duplicate folder keeps unrelated sidecars; the library root stays.
file_put_contents($extra,'stable media');file_put_contents(dirname($extra).'/poster.jpg','poster');$d=proof($extra,$root);applyVerifiedPair(['keep'=>$keep,'remove'=>$extra],$one,$d,$root);check(file_exists(dirname($extra).'/poster.jpg'),'sidecar retained');
$receipt=$root.'/receipt.json';saveReceipt($receipt,['status'=>'TEST_ONLY']);check(json_decode(file_get_contents($receipt),true)['status']==='TEST_ONLY','atomic receipt');
echo "Exact-copy deletion, exclusion, changed-file/hash/symlink/traversal protection, native hash reuse and nonempty-directory retention passed\n";
PHP
php -l "$tmp/library.php"
php "$tmp/test.php" "$tmp/library.php" "$tmp/media"
