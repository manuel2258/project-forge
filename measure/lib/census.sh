# shellcheck shell=bash
# CENSUS_* are read by the measurements, and the workload keys are set by the config that
# common.sh sources, so shellcheck cannot see either end of them from here.
# shellcheck disable=SC2034,SC2154
# What rebuilt, without knowing the language. Three layers: a census of the build directory,
# path classification, and the workload's own parser where it has one. All are recorded; the
# verdict uses the best available. See docs/design/measurement-harness.md.

CENSUS_CREATED=0
CENSUS_MODIFIED=0
CENSUS_TOUCHED=0
CENSUS_DELETED=0
CENSUS_BYTES=0
CENSUS_OWN=0
CENSUS_DEP=0
CENSUS_UNCLASSIFIED=0
CENSUS_CLASSIFICATION=none

# census_take <dir> <outfile> -- paths are relative, so a census of two different checkouts
# is comparable. Runs outside the unit, so it costs nothing against the measured time.
census_take() {
  local dir=$1 out=$2
  if [ -d "$dir" ]; then
    (cd "$dir" && find . -xdev -type f -printf '%P\t%s\t%T@\t%C@\n' 2> /dev/null) |
      LC_ALL=C sort > "$out"
  else
    : > "$out"
  fi
}

# census_diff <before> <after> <changes-out> -- counts, and one line per changed path so a
# surprising number stays diffable by hand.
census_diff() {
  local before=$1 after=$2 changes=$3 key value
  : > "$changes"
  while IFS='=' read -r key value; do
    case $key in
      created) CENSUS_CREATED=$value ;;
      modified) CENSUS_MODIFIED=$value ;;
      touched) CENSUS_TOUCHED=$value ;;
      deleted) CENSUS_DELETED=$value ;;
      bytes) CENSUS_BYTES=$value ;;
      *) ;;
    esac
  done < <(
    LC_ALL=C awk -F'\t' -v changes="$changes" -v before="$before" '
      FILENAME == before { size[$1] = $2; mtime[$1] = $3; ctime[$1] = $4; next }
      {
        seen[$1] = 1
        if (!($1 in size)) {
          print "created\t" $1 > changes; created++; bytes += $2
        } else if (mtime[$1] != $3 || size[$1] != $2) {
          print "modified\t" $1 > changes; modified++; bytes += $2
        } else if (ctime[$1] != $4) {
          print "touched\t" $1 > changes; touched++
        }
      }
      END {
        for (path in size) if (!(path in seen)) deleted++
        printf "created=%d\nmodified=%d\ntouched=%d\ndeleted=%d\nbytes=%d\n",
          created, modified, touched, deleted, bytes
      }
    ' "$before" "$after"
  )
}

# Layer two. Anything matching neither list is counted and printed, so a reader can see how
# much of a verdict rests on globs.
census_classify() {
  local changes=$1 kind path glob matched
  CENSUS_OWN=0
  CENSUS_DEP=0
  CENSUS_UNCLASSIFIED=0
  CENSUS_CLASSIFICATION=none
  [ "${#own_paths[@]}" -gt 0 ] || return 0
  CENSUS_CLASSIFICATION=paths
  while IFS=$'\t' read -r kind path; do
    [ "$kind" = touched ] && continue
    matched=no
    for glob in "${own_paths[@]}"; do
      # shellcheck disable=SC2053  # the glob is the point
      if [[ $path == $glob ]]; then
        matched=own
        break
      fi
    done
    if [ "$matched" = no ]; then
      for glob in "${dep_paths[@]}"; do
        # shellcheck disable=SC2053
        if [[ $path == $glob ]]; then
          matched=dep
          break
        fi
      done
    fi
    case $matched in
      own) CENSUS_OWN=$((CENSUS_OWN + 1)) ;;
      dep) CENSUS_DEP=$((CENSUS_DEP + 1)) ;;
      *)
        # With no dep_paths, "not own" is the dependency side; that is the common shape.
        if [ "${#dep_paths[@]}" -eq 0 ]; then
          CENSUS_DEP=$((CENSUS_DEP + 1))
        else
          CENSUS_UNCLASSIFIED=$((CENSUS_UNCLASSIFIED + 1))
        fi
        ;;
    esac
  done < "$changes"
}

# Layer three. Where a toolchain says out loud what it is compiling this is better evidence,
# and it is the only layer that sees work served from a compilation cache without writing
# files, so it supersedes the globs for the verdict.
census_parse_log() {
  local log=$1 own dep
  [ -n "${parse_rebuilds:-}" ] || return 1
  [ -r "$log" ] || return 1
  own=$("$parse_rebuilds" < "$log" | grep -c '^own' || true)
  dep=$("$parse_rebuilds" < "$log" | grep -c '^dep' || true)
  CENSUS_OWN=$own
  CENSUS_DEP=$dep
  CENSUS_UNCLASSIFIED=0
  CENSUS_CLASSIFICATION=parser
  return 0
}

# Touch every file matching own_sources, which is how the warm_own reference is made: the
# local equivalent of what each M1 variant is asked to do.
census_touch_own_sources() {
  local tree=$1 glob
  for glob in "${own_sources[@]}"; do
    # shellcheck disable=SC2086  # the glob is the point
    (cd "$tree" && find . -path "./$glob" -type f -exec touch {} +) 2> /dev/null || true
  done
}
