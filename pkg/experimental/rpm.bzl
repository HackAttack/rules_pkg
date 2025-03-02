# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Provides rules for creating RPM packages via pkg_filegroup and friends.

pkg_rpm() depends on the existence of an rpmbuild toolchain. Many users will
find to convenient to use the one provided with their system. To enable that
toolchain add the following stanza to WORKSPACE:

```
# Find rpmbuild if it exists.
load("@rules_pkg//toolchains:rpmbuild_configure.bzl", "find_system_rpmbuild")
find_system_rpmbuild(name="rules_pkg_rpmbuild")
```
"""

load("//:providers.bzl", "PackageFilegroupInfo")

rpm_filetype = [".rpm"]

spec_filetype = [".spec", ".spec.in"]

# TODO(nacl): __install, __cp
# {0} is the source, {1} is the dest
#
# TODO(nacl, #292): cp -r does not do the right thing with TreeArtifacts
_INSTALL_FILE_STANZA_FMT = """
install -d %{{buildroot}}/$(dirname {1})
cp -r {0} %{{buildroot}}/{1}
"""

# TODO(nacl): __install
# {0} is the directory name
#
# This may not be strictly necessary, given that they'll be created in the
# CPIO when rpmbuild processes the `%files` list.
_INSTALL_DIR_STANZA_FMT = """
install -d %{{buildroot}}/{0}
"""

# {0} is the name of the link, {1} is the target
_INSTALL_SYMLINK_STANZA_FMT = """
%{{__install}} -d %{{buildroot}}/$(dirname {0})
%{{__ln_s}} {1} %{{buildroot}}/{0}
"""

def _package_contents_metadata(origin_label, grouping_label):
    """Named construct for helping to identify conflicting packaged contents"""
    return struct(
        origin = origin_label if origin_label else "<UNKNOWN>",
        group = grouping_label,
    )

def _conflicting_contents_error(destination, from1, from2, attr_name = "srcs"):
    message = """Destination {destination} is provided by both (1) {from1_origin} and (2) {from2_origin}; please sensure that each destination is provided by exactly one input.

    (1) {from1_origin} is provided from group {from1_group}
    (2) {from2_origin} is provided from group {from2_group}
    """.format(
        destination = destination,
        from1_origin = from1.origin,
        from1_group = from1.group,
        from2_origin = from2.origin,
        from2_group = from2.group,
    )

    fail(message, attr_name)

def _make_filetags(attributes, default_filetag = None):
    """Helper function for rendering RPM spec file tags, like

    ```
    %attr(0755, root, root) %dir
    ```
    """
    template = "%attr({mode}, {user}, {group}) {supplied_filetag}"

    mode = attributes.get("mode", "-")
    user = attributes.get("user", "-")
    group = attributes.get("group", "-")

    supplied_filetag = attributes.get("rpm_filetag", default_filetag)

    return template.format(
        mode = mode,
        user = user,
        group = group,
        supplied_filetag = supplied_filetag or "",
    )

def _pkg_rpm_impl(ctx):
    """Implements the pkg_rpm rule."""

    files = []
    tools = []
    args = ["--name=" + ctx.label.name]

    if ctx.attr.debug:
        args.append("--debug")

    if ctx.attr.rpmbuild_path:
        args.append("--rpmbuild=" + ctx.attr.rpmbuild_path)

        # buildifier: disable=print
        print("rpmbuild_path is deprecated. See the README for instructions on how" +
              " to migrate to toolchains")
    else:
        toolchain = ctx.toolchains["@rules_pkg//toolchains:rpmbuild_toolchain_type"].rpmbuild
        if not toolchain.valid:
            fail("The rpmbuild_toolchain is not properly configured: " +
                 toolchain.name)
        if toolchain.path:
            args.append("--rpmbuild=" + toolchain.path)
        else:
            executable = toolchain.label.files_to_run.executable
            tools.append(executable)
            tools += toolchain.label.default_runfiles.files.to_list()
            args.append("--rpmbuild=%s" % executable.path)

    #### rpm spec "preamble"
    preamble_pieces = []

    # rpm_name takes precedence over name if provided
    if ctx.attr.rpm_name:
        rpm_name = ctx.attr.rpm_name
    else:
        rpm_name = ctx.attr.name
    preamble_pieces.append("Name: " + rpm_name)

    # Version can be specified by a file or inlined.
    if ctx.attr.version_file:
        if ctx.attr.version:
            fail("Both version and version_file attributes were specified")

        preamble_pieces.append("Version: ${VERSION_FROM_FILE}")
        args.append("--version=@" + ctx.file.version_file.path)
        files.append(ctx.file.version_file)
    elif ctx.attr.version:
        preamble_pieces.append("Version: " + ctx.attr.version)
    else:
        fail("None of the version or version_file attributes were specified")

    # Release can be specified by a file or inlined.
    if ctx.attr.release_file:
        if ctx.attr.release:
            fail("Both release and release_file attributes were specified")

        preamble_pieces.append("Release: ${RELEASE_FROM_FILE}")
        args.append("--release=@" + ctx.file.release_file.path)
        files.append(ctx.file.release_file)
    elif ctx.attr.release:
        preamble_pieces.append("Release: " + ctx.attr.release)
    else:
        fail("None of the release or release_file attributes were specified")

    if ctx.attr.summary:
        preamble_pieces.append("Summary: " + ctx.attr.summary)
    if ctx.attr.url:
        preamble_pieces.append("URL: " + ctx.attr.url)
    if ctx.attr.license:
        preamble_pieces.append("License: " + ctx.attr.license)
    if ctx.attr.group:
        preamble_pieces.append("Group: " + ctx.attr.group)
    if ctx.attr.provides:
        preamble_pieces.extend(["Provides: " + p for p in ctx.attr.provides])
    if ctx.attr.conflicts:
        preamble_pieces.extend(["Conflicts: " + c for c in ctx.attr.conflicts])
    if ctx.attr.requires:
        preamble_pieces.extend(["Requires: " + r for r in ctx.attr.requires])
    if ctx.attr.requires_contextual:
        preamble_pieces.extend(
            [
                "Requires({}): {}".format(scriptlet, capability)
                for scriptlet in ctx.attr.requires_contextual.keys()
                for capability in ctx.attr.requires_contextual[scriptlet]
            ],
        )

    # TODO: BuildArch is usually not hardcoded in spec files, unless the package
    # is indeed restricted to a particular CPU architecture, or is actually
    # "noarch".  This will become more of a concern when we start providing
    # source RPMs.
    #
    # In the meantime, this will allow the "architecture" attribute to take
    # effect.
    if ctx.attr.architecture:
        preamble_pieces.append("BuildArch: " + ctx.attr.architecture)

    preamble_file = ctx.actions.declare_file(
        "{}.spec.preamble".format(rpm_name),
    )
    ctx.actions.write(
        output = preamble_file,
        content = "\n".join(preamble_pieces),
    )
    files.append(preamble_file)
    args.append("--preamble=" + preamble_file.path)

    #### %description

    if ctx.attr.description_file:
        if ctx.attr.description:
            fail("Both description and description_file attributes were specified")
        description_file = ctx.file.description_file
    elif ctx.attr.description:
        description_file = ctx.actions.declare_file(
            "{}.spec.description".format(rpm_name),
        )
        ctx.actions.write(
            output = description_file,
            content = ctx.attr.description,
        )
    else:
        fail("None of the description or description_file attributes were specified")

    files.append(description_file)
    args.append("--description=" + description_file.path)

    #### Non-procedurally-generated scriptlets

    substitutions = {}
    if ctx.attr.pre_scriptlet_file:
        if ctx.attr.pre_scriptlet:
            fail("Both pre_scriptlet and pre_scriptlet_file attributes were specified")
        pre_scriptlet_file = ctx.file.pre_scriptlet_file
        files.append(pre_scriptlet_file)
        args.append("--pre_scriptlet=" + pre_scriptlet_file.path)
    elif ctx.attr.pre_scriptlet:
        scriptlet_file = ctx.actions.declare_file(ctx.label.name + ".pre_scriptlet")
        files.append(scriptlet_file)
        ctx.actions.write(scriptlet_file, ctx.attr.pre_scriptlet)
        args.append("--pre_scriptlet=" + scriptlet_file.path)

    if ctx.attr.post_scriptlet_file:
        if ctx.attr.post_scriptlet:
            fail("Both post_scriptlet and post_scriptlet_file attributes were specified")
        post_scriptlet_file = ctx.file.post_scriptlet_file
        files.append(post_scriptlet_file)
        args.append("--post_scriptlet=" + post_scriptlet_file.path)
    elif ctx.attr.post_scriptlet:
        scriptlet_file = ctx.actions.declare_file(ctx.label.name + ".post_scriptlet")
        files.append(scriptlet_file)
        ctx.actions.write(scriptlet_file, ctx.attr.post_scriptlet)
        args.append("--post_scriptlet=" + scriptlet_file.path)

    if ctx.attr.preun_scriptlet_file:
        if ctx.attr.preun_scriptlet:
            fail("Both preun_scriptlet and preun_scriptlet_file attributes were specified")
        preun_scriptlet_file = ctx.file.preun_scriptlet_file
        files.append(preun_scriptlet_file)
        args.append("--preun_scriptlet=" + preun_scriptlet_file.path)
    elif ctx.attr.preun_scriptlet:
        scriptlet_file = ctx.actions.declare_file(ctx.label.name + ".preun_scriptlet")
        files.append(scriptlet_file)
        ctx.actions.write(scriptlet_file, ctx.attr.preun_scriptlet)
        args.append("--preun_scriptlet=" + scriptlet_file.path)

    if ctx.attr.postun_scriptlet_file:
        if ctx.attr.postun_scriptlet:
            fail("Both postun_scriptlet and postun_scriptlet_file attributes were specified")
        postun_scriptlet_file = ctx.file.postun_scriptlet_file
        files.append(postun_scriptlet_file)
        args.append("--postun_scriptlet=" + postun_scriptlet_file.path)
    elif ctx.attr.postun_scriptlet:
        scriptlet_file = ctx.actions.declare_file(ctx.label.name + ".postun_scriptlet")
        files.append(scriptlet_file)
        ctx.actions.write(scriptlet_file, ctx.attr.postun_scriptlet)
        args.append("--postun_scriptlet=" + scriptlet_file.path)

    #### Expand the spec file template; prepare data files

    spec_file = ctx.actions.declare_file("%s.spec" % rpm_name)
    ctx.actions.expand_template(
        template = ctx.file.spec_template,
        output = spec_file,
        substitutions = substitutions,
    )
    args.append("--spec_file=" + spec_file.path)
    files.append(spec_file)

    args.append("--out_file=" + ctx.outputs.rpm.path)

    # Add data files.
    if ctx.file.changelog:
        files.append(ctx.file.changelog)
        args.append(ctx.file.changelog.path)

    files += ctx.files.srcs

    #### Sanity checking

    # Ensure that no destinations collide.  RPMs that fail this check may be
    # sane, but the output may also create hard-to-debug issues.  Better to err
    # on the side of correctness here.
    dest_check_map = {}
    for dep in ctx.attr.srcs:
        # TODO(nacl, #191): This loop should be consolidated with the install
        # script-generating loop below, as they're iterating on the same data.

        # NOTE: This does not detect cases where directories are not named
        # consistently.  For example, all of these may collide in reality, but
        # won't be detected by the below:
        #
        # 1) usr/lib/libfoo.a
        # 2) /usr/lib/libfoo.a
        # 3) %{_libdir}/libfoo.a
        #
        # The rule of thumb, regardless of how these checks below are done, is
        # to be consistent with path naming conventions.
        #
        # There is also an unsolved question of determining how to handle
        # subdirectories of "PackageFilesInfo" targets that are actually
        # directories.

        # d is a Target
        pfg_info = dep[PackageFilegroupInfo]
        for entry, origin in pfg_info.pkg_files:
            for dest, src in entry.dest_src_map.items():
                metadata = _package_contents_metadata(origin, dep.label)
                if dest in dest_check_map:
                    _conflicting_contents_error(dest, metadata, dest_check_map[dest])
                else:
                    dest_check_map[dest] = metadata

        for entry, origin in pfg_info.pkg_dirs:
            for dest in entry.dirs:
                metadata = _package_contents_metadata(origin, dep.label)
                if dest in dest_check_map:
                    _conflicting_contents_error(dest, metadata, dest_check_map[dest])
                else:
                    dest_check_map[dest] = metadata

        for entry, origin in pfg_info.pkg_symlinks:
            metadata = _package_contents_metadata(origin, dep.label)
            if entry.destination in dest_check_map:
                _conflicting_contents_error(entry.destination, metadata, dest_check_map[entry.destination])
            else:
                dest_check_map[entry.destination] = metadata

    #### Procedurally-generated scripts/lists (%install, %files)

    # Build up the install script
    install_script_pieces = []
    if ctx.attr.debug:
        install_script_pieces.append("set -x")

    # Build up the RPM files list (%files -f)
    rpm_files_list = []

    # Iterate over all incoming data, creating datasets as we go from the
    # actual contents of the RPM.
    #
    # This is a naive approach to script creation is almost guaranteed to
    # produce an installation script that is longer than necessary.  A better
    # implementation would track directories that are created and ensure that
    # they aren't unnecessarily recreated.
    for dep in ctx.attr.srcs:
        pfg_info = dep[PackageFilegroupInfo]
        for entry, _ in pfg_info.pkg_files:
            file_base = _make_filetags(entry.attributes)

            for dest, src in entry.dest_src_map.items():
                rpm_files_list.append(file_base + " /" + dest)

                install_script_pieces.append(_INSTALL_FILE_STANZA_FMT.format(
                    src.path,
                    dest,
                ))
        for entry, _ in pfg_info.pkg_dirs:
            file_base = _make_filetags(entry.attributes, "%dir")
            for d in entry.dirs:
                rpm_files_list.append(file_base + " /" + d)

                install_script_pieces.append(_INSTALL_DIR_STANZA_FMT.format(
                    d,
                ))
        for entry, _ in pfg_info.pkg_symlinks:
            file_base = _make_filetags(entry.attributes)
            rpm_files_list.append(file_base + " /" + entry.destination)
            install_script_pieces.append(_INSTALL_SYMLINK_STANZA_FMT.format(
                entry.destination,
                entry.source,
            ))

    install_script = ctx.actions.declare_file("{}.spec.install".format(rpm_name))
    ctx.actions.write(
        install_script,
        "\n".join(install_script_pieces),
    )
    files.append(install_script)
    args.append("--install_script=" + install_script.path)

    rpm_files_file = ctx.actions.declare_file(
        "{}.spec.files".format(rpm_name),
    )
    ctx.actions.write(
        rpm_files_file,
        "\n".join(rpm_files_list),
    )
    files.append(rpm_files_file)
    args.append("--file_list=" + rpm_files_file.path)

    additional_rpmbuild_args = []
    if ctx.attr.binary_payload_compression:
        additional_rpmbuild_args.extend([
            "--define",
            "_binary_payload {}".format(ctx.attr.binary_payload_compression),
        ])

    args.extend(["--rpmbuild_arg=" + a for a in additional_rpmbuild_args])

    for f in ctx.files.srcs:
        args.append(f.path)

    #### Call the generator script.

    ctx.actions.run(
        mnemonic = "MakeRpm",
        executable = ctx.executable._make_rpm,
        use_default_shell_env = True,
        arguments = args,
        inputs = files,
        outputs = [ctx.outputs.rpm],
        env = {
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "PYTHONIOENCODING": "UTF-8",
            "PYTHONUTF8": "1",
        },
        tools = tools,
    )

    #### Output construction

    # Link the RPM to the expected output name.
    ctx.actions.symlink(
        output = ctx.outputs.out,
        target_file = ctx.outputs.rpm,
    )

    # Link the RPM to the RPM-recommended output name if possible.
    if "rpm_nvra" in dir(ctx.outputs):
        ctx.actions.symlink(
            output = ctx.outputs.rpm_nvra,
            target_file = ctx.outputs.rpm,
        )

# TODO(nacl): this relies on deprecated behavior (should use Providers
# instead), it should be removed at some point.
def _pkg_rpm_outputs(name, rpm_name, version, release):
    actual_rpm_name = rpm_name or name
    outputs = {
        "out": actual_rpm_name + ".rpm",
        "rpm": actual_rpm_name + "-%{architecture}.rpm",
    }

    # The "rpm_nvra" output follows the recommended package naming convention of
    # Name-Version-Release.Arch.rpm
    # See http://ftp.rpm.org/max-rpm/ch-rpm-file-format.html
    if version and release:
        outputs["rpm_nvra"] = actual_rpm_name + "-%{version}-%{release}.%{architecture}.rpm"

    return outputs

# Define the rule.
pkg_rpm = rule(
    doc = """Creates an RPM format package via `pkg_filegroup` and friends.

    The uses the outputs of the rules in `mappings.bzl` to construct arbitrary
    RPM packages.  Attributes of this rule provide preamble information and
    scriptlets, which are then used to compose a valid RPM spec file.

    This rule will fail at analysis time if:

    - Any `data` input may create the same destination, regardless of other
      attributes.

    Currently, two outputs are guaranteed to be produced: "%{name}.rpm", and
    "%{name}-%{architecture}.rpm". If the "version" and "release" arguments are
    non-empty, a third output will be produced, following the RPM-recommended
    N-V-R.A format (Name-Version-Release.Architecture.rpm). Note that due to
    the fact that rule implementations cannot access the contents of files,
    the "version_file" and "release_file" arguments will not create an output
    using N-V-R.A format.

    This rule only functions on UNIXy platforms. The following tools must be
    available on your system for this to function properly:

    - `rpmbuild` (as specified in `rpmbuild_path`, or available in `$PATH`)

    - GNU coreutils.  BSD coreutils may work, but are not tested.

    To set RPM file attributes (like `%config` and friends), set the
    `rpm_filetag` in corresponding packaging rule (`pkg_files`, etc).  The value
    is prepended with "%" and added to the `%files` list, for example:

    ```
    attrs = {"rpm_filetag": ("config(missingok, noreplace)",)},
    ```

    Is the equivalent to `%config(missingok, noreplace)` in the `%files` list.

    """,
    # @unsorted-dict-items
    attrs = {
        "rpm_name": attr.string(
            doc = """Optional; RPM name override.

            If not provided, the `name` attribute of this rule will be used
            instead.

            This influences values like the spec file name, and the name of the
            output RPM.

            """,
        ),
        "version": attr.string(
            doc = """RPM "Version" tag.

            Exactly one of `version` or `version_file` must be provided.
            """,
        ),
        "version_file": attr.label(
            doc = """File containing RPM "Version" tag.""",
            allow_single_file = True,
        ),
        "release": attr.string(
            doc = """RPM "Release" tag

            Exactly one of `release` or `release_file` must be provided.
            """,
        ),
        "release_file": attr.label(
            doc = """File containing RPM "Release" tag.""",
            allow_single_file = True,
        ),
        "group": attr.string(
            doc = """Optional; RPM "Group" tag.

            NOTE: some distributions (as of writing, Fedora > 17 and CentOS/RHEL
            > 5) have deprecated this tag.  Other distributions may require it,
            but it is harmless in any case.

            """,
        ),
        # TODO(nacl): this should be augmented to use bazel platforms, and
        # should not really set BuildArch.
        "architecture": attr.string(
            doc = """Package architecture.

            This currently sets the `BuildArch` tag, which influences the output
            architecture of the package.

            Typically, `BuildArch` only needs to be set when the package is
            known to be cross-platform (e.g. written in an interpreted
            language), or, less common, when it is known that the application is
            only valid for specific architectures.

            When no attribute is provided, this will default to your host's
            architecture.  This is usually what you want.

            """,
        ),
        "license": attr.string(
            doc = """RPM "License" tag.

            The software license for the code distributed in this package.

            The underlying RPM builder requires you to put something here; if
            your package is not going to be distributed, feel free to set this
            to something like "Internal".

            """,
            mandatory = True,
        ),
        "summary": attr.string(
            doc = """RPM "Summary" tag.

            One-line summary of this package.  Must not contain newlines.

            """,
            mandatory = True,
        ),
        "url": attr.string(
            doc = """RPM "URL" tag; this project/vendor's home on the Internet.""",
        ),
        "description": attr.string(
            doc = """Multi-line description of this package, corresponds to RPM %description.

            Exactly one of `description` or `description_file` must be provided.
            """,
        ),
        "description_file": attr.label(
            doc = """File containing a multi-line description of this package, corresponds to RPM
            %description.""",
            allow_single_file = True,
        ),
        # TODO: this isn't consumed yet
        "changelog": attr.label(
            allow_single_file = True,
        ),
        "srcs": attr.label_list(
            doc = """Mapping groups to include in this RPM.

            These are typically brought into life as `pkg_filegroup`s.
            """,
            mandatory = True,
            providers = [PackageFilegroupInfo],
        ),
        "debug": attr.bool(
            doc = """Debug the RPM helper script and RPM generation""",
            default = False,
        ),
        "pre_scriptlet": attr.string(
            doc = """RPM `%pre` scriptlet.  Currently only allowed to be a shell script.

            `pre_scriptlet` and `pre_scriptlet_file` are mutually exclusive.
            """,
        ),
        "pre_scriptlet_file": attr.label(
            doc = """File containing the RPM `%pre` scriptlet""",
            allow_single_file = True,
        ),
        "post_scriptlet": attr.string(
            doc = """RPM `%post` scriptlet.  Currently only allowed to be a shell script.

            `post_scriptlet` and `post_scriptlet_file` are mutually exclusive.
            """,
        ),
        "post_scriptlet_file": attr.label(
            doc = """File containing the RPM `%post` scriptlet""",
            allow_single_file = True,
        ),
        "preun_scriptlet": attr.string(
            doc = """RPM `%preun` scriptlet.  Currently only allowed to be a shell script.

            `preun_scriptlet` and `preun_scriptlet_file` are mutually exclusive.
            """,
        ),
        "preun_scriptlet_file": attr.label(
            doc = """File containing the RPM `%preun` scriptlet""",
            allow_single_file = True,
        ),
        "postun_scriptlet": attr.string(
            doc = """RPM `%postun` scriptlet.  Currently only allowed to be a shell script.

            `postun_scriptlet` and `postun_scriptlet_file` are mutually exclusive.
            """,
        ),
        "postun_scriptlet_file": attr.label(
            doc = """File containing the RPM `%postun` scriptlet""",
            allow_single_file = True,
        ),
        "conflicts": attr.string_list(
            doc = """List of capabilities that conflict with this package when it is installed.

            Cooresponds to the "Conflicts" preamble tag.

            See also: https://rpm.org/user_doc/dependencies.html
            """,
        ),
        "provides": attr.string_list(
            doc = """List of rpm capabilities that this package provides.

            Cooresponds to the "Provides" preamble tag.

            See also: https://rpm.org/user_doc/dependencies.html
            """,
        ),
        "requires": attr.string_list(
            doc = """List of rpm capability expressions that this package requires.

            Corresponds to the "Requires" preamble tag.

            See also: https://rpm.org/user_doc/dependencies.html
            """,
        ),
        "requires_contextual": attr.string_list_dict(
            doc = """Contextualized requirement specifications

            This is a map of various properties (often scriptlet types) to
            capability name specifications, e.g.:

            ```python
            {"pre": ["GConf2"],"post": ["GConf2"], "postun": ["GConf2"]}
            ```

            Which causes the below to be added to the spec file's preamble:

            ```
            Requires(pre): GConf2
            Requires(post): GConf2
            Requires(postun): GConf2
            ```

            This is most useful for ensuring that required tools exist when
            scriptlets are run, although other properties are known.  Valid keys
            for this attribute may include, but are not limited to:

            - `pre`
            - `post`
            - `preun`
            - `postun`
            - `pretrans`
            - `posttrans`

            For capabilities that are always required by packages at runtime,
            use the `requires` attribute instead.

            See also: https://rpm.org/user_doc/more_dependencies.html

            NOTE: `pkg_rpm` does not check if the keys of this dictionary are
            acceptable to `rpm(8)`.
            """,
        ),
        "spec_template": attr.label(
            doc = """Spec file template.

            Use this if you need to add additional logic to your spec files that
            is not available by default.

            In most cases, you should not need to override this attribute.
            """,
            allow_single_file = spec_filetype,
            default = "//experimental:template.spec.in",
        ),
        "binary_payload_compression": attr.string(
            doc = """Compression mode used for this RPM

            Must be a form that `rpmbuild(8)` knows how to process, which will
            depend on the version of `rpmbuild` in use.  The value corresponds
            to the `%_binary_payload` macro and is set on the `rpmbuild(8)`
            command line if this attribute is provided.

            Some examples of valid values (which may not be supported on your
            system) can be found [here](https://git.io/JU9Wg).  On CentOS
            systems (also likely Red Hat and Fedora), you can find some
            supported values by looking for `%_binary_payload` in
            `/usr/lib/rpm/macros`.  Other systems have similar files and
            configurations.

            If not provided, the compression mode will be computed using normal
            RPM spec file processing.  Defaults may vary per distribution:
            consult its documentation for more details.

            WARNING: Bazel is currently not aware of action threading requirements
            for non-test actions.  Using threaded compression may result in
            overcommitting your system.
            """,
        ),
        "rpmbuild_path": attr.string(
            doc = """Path to a `rpmbuild` binary.  Deprecated in favor of the rpmbuild toolchain""",
        ),
        # Implicit dependencies.
        "_make_rpm": attr.label(
            default = Label("//:make_rpm"),
            cfg = "exec",
            executable = True,
            allow_files = True,
        ),
    },
    executable = False,
    outputs = _pkg_rpm_outputs,
    implementation = _pkg_rpm_impl,
    toolchains = ["@rules_pkg//toolchains:rpmbuild_toolchain_type"],
)
