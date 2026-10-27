defmodule ForgeCore.Secret do
  @moduledoc """
  What a project secret may be called. `docs/design/secrets.md` § Names.

  A secret reaches a job as an environment variable of its own name, so its name decides which
  variable it sets — and some variables are not a project's to set. **The reserved list is a
  security rule, not tidiness.** `ANTHROPIC_BASE_URL` in a job's environment sends the harness's
  requests, carrying a credential from the project's pool that may be another member's, to a host
  of the secret-setter's choosing; `HTTPS_PROXY` does the same to all of a job's traffic;
  `NODE_OPTIONS` and `LD_PRELOAD` load code into the harness; `SHELLOPTS=xtrace` with a `PS4`
  holding a command substitution runs that command in every bash the job starts. The platform
  setting its own variables after a secret's would not help: these are names it does not set.

  **Two sources, kept apart so each can be checked against its own.**

  - **Ours**: every prefix the platform, the harness, Nix, git, npm and TLS read, and every name
    a job's environment already carries — `ForgeWorker.Job.Exec`'s allowlist, what the runner adds,
    and what the harness driver sets for its own process. The worker's suite asserts that both the
    allowlist and the driver's names stay inside this list.
  - **The harness's own**, copied verbatim from `claude-code` 2.1.266: the variables it strips
    from a shell's environment, the search-path variables it lists beside them, and the 188 names
    and the patterns it treats as making a program run code. A name our format already refuses —
    lower case, a leading underscore — is kept, so the next version's lists can be compared with
    these line for line. **2.1.266 is a version somebody read, not a version anything pins**: the
    worker image no longer carries a Claude Code at all, and each machine installs whatever
    `claude.ai/install.sh` gives it at first boot (`docs/design/worker-tier.md` § Updating a
    worker), so what a worker runs now moves without this repository changing. Read the lists
    again when it has: they are this list's provenance, and a harness that learns a new name has
    found one this list is missing.

  Nothing claims the result is complete. It is every name either source knows to redirect a job
  or load code into it.

  **One list, for both ends.** The platform refuses a reserved name whenever a secret is set and in
  a workflow's `secrets`; the worker refuses one again when it composes a job's environment
  (`ForgeWorker.Job.Secrets.env/1`), so a row written around the changeset cannot put one in front
  of a harness. Two copies
  of a rule that have to agree are two places for them to disagree, which is why it is here.
  """

  @format ~r/\A[A-Z][A-Z0-9_]{0,63}\z/

  @ours_prefixes ~w(FORGE_ ANTHROPIC_ CLAUDE_ NODE_ BUN_ NPM_CONFIG_ NIX_ GIT_ SSL_ BASH_)

  # `DISABLE_AUTOUPDATER` is here because the worker sets it on every harness process
  # (`ForgeWorker.Harness.ClaudeCode.command/3`) to stop a job's Claude Code replacing itself with
  # a build nothing has reported. A secret of that name would be loaded after it and win, which is
  # the one way a project could turn it back on.
  @ours_names ~w(PATH HOME USER LOGNAME SHELL TERM HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY
                 DISABLE_AUTOUPDATER)

  @harness_prefixes ~w(
    LD_ DYLD_ BASH_FUNC_ __BASH_FUNC< LC_ DOTNET_ COMPLUS_ COR_ CORECLR_ APPDOMAIN_MANAGER_
  )

  @harness_shell ~w(
    ENV BASH_ENV SHELLOPTS PS4 GCONV_PATH IFS PWD CDPATH OLDPWD TMOUT POSIXLY_CORRECT BASHOPTS
    BASH_COMPAT EXECIGNORE BASH_LOADABLES_PATH GLOBIGNORE GLOBSORT LOCPATH PATH_LOCALE NLSPATH
    LANG TMPDIR TMP TEMP
  )

  @harness_search_paths ~w(
    PATH PYTHONPATH NODE_PATH RUBYLIB PERL5LIB PERLLIB GEM_PATH CLASSPATH DYLD_LIBRARY_PATH
    DYLD_FRAMEWORK_PATH LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
    R_LIBS R_LIBS_USER R_LIBS_SITE
  )

  @harness_runs_code ~w(
    GOFLAGS RUSTFLAGS GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_EXTERNAL_DIFF GIT_PROXY_COMMAND
    SUDO_ASKPASS ZDOTDIR CDPATH GCONV_PATH NLSPATH DOTNET_STARTUP_HOOKS npm_config_node_options
    NPM_CONFIG_NODE_OPTIONS LESSOPEN LESSCLOSE MANPAGER MAVEN_OPTS MAVEN_ARGS MAVEN_CONFIG
    ANT_OPTS ANT_ARGS GRADLE_OPTS JAVA_OPTS JVM_OPTS LEIN_JVM_OPTS ES_JAVA_OPTS SBT_OPTS
    SONAR_SCANNER_OPTS SONAR_SCANNER_JAVA_OPTS MAKEFLAGS GNUMAKEFLAGS MFLAGS MAKEFILES CFLAGS
    CXXFLAGS CPPFLAGS LDFLAGS LDLIBS CC CXX CPP MAKE AR AS LD LEX YACC RANLIB ARFLAGS RANLIBFLAGS
    NM STRIP OBJCOPY OBJDUMP PKG_CONFIG FC F77 FFLAGS FCFLAGS CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS
    CGO_FFLAGS CGO_LDFLAGS HOST_CC HOST_CXX HOST_AR HOST_RANLIB HOST_ARFLAGS HOST_CFLAGS
    HOST_CXXFLAGS TARGET_RANLIB TARGET_ARFLAGS TARGET_CC TARGET_CXX TARGET_AR TARGET_CFLAGS
    TARGET_CXXFLAGS GCC_EXEC_PREFIX COMPILER_PATH DEPENDENCIES_OUTPUT SUNPRO_DEPENDENCIES GOAUTH
    GOTOOLCHAIN OPENSSL_ENGINES SHELLOPTS BASHOPTS PS4 PROMPT_COMMAND GIT_SSH_COMMAND GIT_SSH
    GIT_EXEC_PATH GIT_ASKPASS SSH_ASKPASS GIT_PAGER PAGER EDITOR VISUAL BROWSER PYTHONWARNINGS
    PYTHONBREAKPOINT PERL5DB NODE_REPL_EXTERNAL_MODULE JAVA_TOOL_OPTIONS _JAVA_OPTIONS
    JDK_JAVA_OPTIONS IBM_JAVA_OPTIONS OPENJ9_JAVA_OPTIONS NODE_OPTIONS NODE_COMPILE_CACHE
    PYTHONSTARTUP PYTHONHOME PYTHONUSERBASE BASH_ENV ENV PERL5OPT RUBYOPT GEM_HOME
    RUBYGEMS_GEMDEPS BUNDLE_GEMFILE OPENSSL_CONF OPENSSL_MODULES DYLD_INSERT_LIBRARIES LD_PRELOAD
    LD_AUDIT BUN_OPTIONS npm_config_script_shell NPM_CONFIG_SCRIPT_SHELL RUSTC RUSTC_WRAPPER
    RUSTC_WORKSPACE_WRAPPER RUSTDOC CARGO_BUILD_RUSTC CARGO_BUILD_RUSTC_WRAPPER
    CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER CARGO_BUILD_RUSTDOC CARGO_BUILD_RUSTFLAGS RUSTDOCFLAGS
    CARGO_BUILD_RUSTDOCFLAGS CARGO_ENCODED_RUSTDOCFLAGS CARGO_ENCODED_RUSTFLAGS GOROOT
    PSModulePath PSMODULEPATH JAVA_HOME JAVACMD JDK_HOME DOTNET_ROOT COREPACK_HOME VIRTUAL_ENV
    CONDA_PREFIX PYENV_ROOT PYENV_VERSION VOLTA_HOME ASDF_DIR ASDF_DATA_DIR RBENV_ROOT
    RBENV_VERSION NODENV_ROOT NODENV_VERSION GOENV_ROOT GOENV_VERSION JENV_ROOT JENV_VERSION
    PLENV_ROOT PLENV_VERSION PERL5SHELL RUBYSHELL NODE_V8_COVERAGE NODE_REDIRECT_WARNINGS
    AWS_PAGER GH_PAGER CLOUDSDK_PYTHON CLOUDSDK_PYTHON_ARGS CLOUDSDK_GSUTIL_PYTHON
    CLOUDSDK_BQ_PYTHON UV_PYTHON GH_BROWSER SOPS_GPG_EXEC RSYNC_RSH CVS_RSH TAR_OPTIONS
    DOCKER_CLI_PLUGIN_EXTRA_DIRS R_PROFILE R_PROFILE_USER R_ENVIRON R_ENVIRON_USER
  )

  @harness_windows ~w(
    DEVPATH __PSLOCKDOWNPOLICY PSMODULEANALYSISCACHEPATH PSMODULEPATH PATH PATHEXT COMSPEC TERM
  )

  # The patterns the harness reads beside its 188 names, as one expression, verbatim: names ending
  # in `_PAGER`, `_EDITOR` or `_EXTERNAL_DIFF`, a cargo target's runner or linker, a compiler named
  # per architecture. It is applied to names the format has already made upper case.
  @harness_runs_code_pattern ~r/^(?:DYLD_|LD_|BASH_FUNC_|GIT_CONFIG_|LUA_|TF_CLI_ARGS|CARGO_ALIAS_|CARGO_TARGET_[A-Z0-9_]+_(?:RUNNER|LINKER|RUSTFLAGS|RUSTDOCFLAGS)$|(?:CC|CXX|AR|RANLIB|(?:AR|RANLIB)FLAGS|FC?FLAGS|CFLAGS|CXXFLAGS|LDFLAGS)_(?:X86_64|I[3-6]86|AARCH64|ARM|RISCV|WASM|POWERPC|S390X|MIPS|SPARC|LOONGARCH|THUMB)[A-Z0-9_-]*$|[A-Z0-9][A-Z0-9_]*_(?:EXTERNAL_DIFF|PAGER|EDITOR)$)/

  @reserved_prefixes @ours_prefixes ++ @harness_prefixes

  @reserved_names MapSet.new(
                    @ours_names ++
                      @harness_shell ++
                      @harness_search_paths ++ @harness_runs_code ++ @harness_windows
                  )

  @doc """
  Whether `name` may be a secret's: `:ok`, or why not.

  `{:error, :format}` for anything that is not an upper-case environment-variable name of at most
  64 characters — lower case included, which also keeps out the lower-case proxy variables the
  worker passes through. `{:error, :reserved}` for a name on the lists above.
  """
  @spec validate_name(term()) :: :ok | {:error, :format | :reserved}
  def validate_name(name) when is_binary(name) do
    cond do
      not Regex.match?(@format, name) -> {:error, :format}
      reserved?(name) -> {:error, :reserved}
      true -> :ok
    end
  end

  def validate_name(_name), do: {:error, :format}

  @doc "Whether `name` is one a secret may never have, whatever else is true of it."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(name) when is_binary(name) do
    MapSet.member?(@reserved_names, name) or String.starts_with?(name, @reserved_prefixes) or
      Regex.match?(@harness_runs_code_pattern, name)
  end
end
