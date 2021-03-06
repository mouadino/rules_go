load('//go/private:go_toolchain.bzl', 'go_toolchain_type')

_bazelrc = """
build --fetch=False --verbose_failures --sandbox_debug --test_output=errors --spawn_strategy=standalone --genrule_strategy=standalone
test --test_strategy=standalone
"""

def _bazel_test_script_impl(ctx):
  script_content = ''
  workspace_content = ''
  go_version = ''
  if ctx.attr.go_version:
    go_version = 'go_version = "%s"' % ctx.attr.go_version
  subdir = ""
  if ctx.attr.subdir:
    subdir = ctx.attr.subdir + "/"
  # Build the bazel startup args
  bazelrc = ctx.new_file(subdir + ".bazelrc")
  args = ["--bazelrc={0}".format(bazelrc.basename), "--nomaster_blazerc"]
  if ctx.attr.batch:
    args += ["--batch"]
  # Add the command and any command specific args
  args += [ctx.attr.command]
  for ext in ctx.attr.externals:
    root = ext.label.workspace_root
    _,_,ws = root.rpartition("/")
    workspace_content += 'local_repository(name = "{0}", path = "{1}/{2}")\n'.format(ws, ctx.attr._execroot.path, root)
  go_toolchain = ctx.attr._go_toolchain[go_toolchain_type]
  workspace_content += 'local_repository(name = "{0}", path = "{1}")\n'.format(go_toolchain.sdk, go_toolchain.root.path)
  # finalise the workspace file
  workspace_content += 'load("@io_bazel_rules_go//go:def.bzl", "go_repositories")\n'
  workspace_content += 'go_repositories({0})\n'.format(go_version)
  if ctx.attr.workspace:
    workspace_content += ctx.attr.workspace
  workspace_file = ctx.new_file(subdir + "WORKSPACE")
  ctx.file_action(output=workspace_file, content=workspace_content)
  # finalise the script
  args += ctx.attr.args + [ctx.attr.target]
  script_content += 'BASE=$(pwd)\n'
  script_content += 'cd {0}\n'.format(ctx.label.package)
  script_content += 'PACKAGE=$(pwd)\n'
  if ctx.attr.subdir:
    script_content += 'cd {0}\n'.format(ctx.attr.subdir)
    script_content += 'cp BUILD.in BUILD.bazel\n'
  script_content += 'WORKSPACE=$(pwd)\n'
  if ctx.attr.prepare:
    script_content += ctx.attr.prepare
  script_content += 'cd $WORKSPACE\n'
  script_content += 'echo {0} {1}\n'.format(ctx.attr._execroot.bazel, " ".join(args))
  script_content += '{0} {1}\n'.format(ctx.attr._execroot.bazel, " ".join(args))
  script_content += 'result=$?\n'
  if ctx.attr.check:
    script_content += ctx.attr.check
  script_content += "exit $result\n"
  script_file = ctx.new_file(ctx.label.name+".bash")
  ctx.file_action(output=script_file, executable=True, content=script_content)
  # finalise the bazel options
  ctx.file_action(output=bazelrc, content=_bazelrc)
  return struct(
    files = depset([script_file]),
    runfiles = ctx.runfiles([workspace_file, bazelrc])
  )

_bazel_test_script = rule(
    _bazel_test_script_impl,
    attrs = {
        "batch": attr.bool(default=True),
        "command": attr.string(mandatory=True, values=["build", "test", "coverage"]),
        "args": attr.string_list(default=[]),
        "subdir": attr.string(),
        "target": attr.string(mandatory=True),
        "externals": attr.label_list(allow_files=True),
        "go_version": attr.string(),
        "workspace": attr.string(),
        "prepare": attr.string(),
        "check": attr.string(),
        "_go_toolchain": attr.label(default = Label("@io_bazel_rules_go_toolchain//:go_toolchain")),
        "_execroot": attr.label(default = Label("@test_environment//:execroot")),
    }
)

def bazel_test(name, batch = None, command = None, args=None, subdir = None, target = None, go_version = None, tags=[], workspace="", prepare="", check=""):
  script_name = name+"_script"
  externals = [
      "@io_bazel_rules_go//:README.md",
      "@local_config_cc//:cc_wrapper",
      "@io_bazel_rules_go_toolchain//:BUILD.bazel",
  ]
  _bazel_test_script(
      name = script_name,
      batch = batch,
      command = command,
      args = args,
      subdir = subdir,
      target = target,
      externals = externals,
      go_version = go_version,
      workspace = workspace,
      prepare = prepare,
      check = check,
  )
  native.sh_test(
      name = name,
      size = "large",
      timeout = "moderate",
      srcs = [script_name],
      tags = ["local", "bazel"] + tags,
      data = native.glob(["**/*"]) + externals + [
          "//tests:rules_go_deps",
          "//go/tools/gazelle/gazelle",
      ],
  )

def _md5_sum_impl(ctx):
  out = ctx.new_file(ctx.label.name+".md5")
  ctx.action(
    inputs = ctx.files.srcs,
    outputs = [out],
    executable = ctx.file._md5sum,
    arguments = ["-output", out.path] + [src.path for src in ctx.files.srcs],
  )
  return struct(files=depset([out]))

md5_sum = rule(
    _md5_sum_impl,
    attrs = { 
      "srcs": attr.label_list(allow_files=True),
      "_md5sum":  attr.label(allow_files=True, single_file=True, default=Label("@io_bazel_rules_go//go/tools/builders:md5sum")),
    },
)

def _test_environment_impl(ctx):
  execroot, _, ws = str(ctx.path(".")).rpartition("/external/")
  bazel = ""
  if "BAZEL" in ctx.os.environ:
    bazel = ctx.os.environ["BAZEL"]
  elif "BAZEL_VERSION" in ctx.os.environ:
    home = ctx.os.environ["HOME"]
    bazel = home + "/.bazel/{0}/bin/bazel".format(ctx.os.environ["BAZEL_VERSION"])
  if bazel == "" or not ctx.path(bazel).exists:
    bazel = ctx.which("bazel")
  if ctx.name != ws:
    fail("workspace did not match, expected:", ctx.name, "got:", ws)
  ctx.file("WORKSPACE", """
workspace(name = "%s")
""" % ctx.name)
  ctx.file("BUILD.bazel", """
load("@io_bazel_rules_go//tests:bazel_tests.bzl", "execroot")
execroot(
    name = "execroot",
    path = "{0}",
    bazel = "{1}",
    visibility = ["//visibility:public"],
)
""".format(execroot, bazel))

_test_environment = repository_rule(
    implementation = _test_environment_impl,
    attrs = {},
    environ = [
      "BAZEL",
      "BAZEL_VERSION",
      "HOME",
    ],
)

def test_environment():
  _test_environment(name="test_environment")

def _execroot_impl(ctx):
  return struct(
    path = ctx.attr.path,
    bazel = ctx.attr.bazel,
  )

execroot = rule(
    _execroot_impl, 
    attrs = {
        "path": attr.string(mandatory = True),
        "bazel": attr.string(mandatory = True),
    }
)
