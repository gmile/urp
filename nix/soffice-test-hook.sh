preCheckHooks+=(sofficeStart)
postCheckHooks+=(sofficeStop)

sofficeStart() {
  echo 'starting soffice'
  @soffice@ &>"$NIX_BUILD_TOP/soffice.log" &
  sofficePid=$!
  timeout 60 bash -c 'until (exec 3<>/dev/tcp/127.0.0.1/2002) 2>/dev/null; do sleep 1; done' || {
    cat "$NIX_BUILD_TOP/soffice.log"
    false
  }
}

sofficeStop() {
  echo 'stopping soffice'
  kill "$sofficePid" 2>/dev/null || true
}
