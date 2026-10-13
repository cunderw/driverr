# Third-party notices

Driverr's own code is under the [MIT license](LICENSE). This file lists the third-party
material that the repository contains or that the app links, with the license and copyright
text each one asks to travel with it.

Every license text and notice below was copied, unchanged, from the file named in the same
section, at the revision named. Nothing was written from memory. Dependency versions are the
ones pinned in [`DriverrKit/Package.resolved`](DriverrKit/Package.resolved) and
[`Driverr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`](Driverr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved).

The app bundle carries this file as a resource. The app does not show it.

## Swift packages

SwiftPM resolves these nine packages. `swift-argument-parser` is listed because SwiftPM
resolves it. This file does not say whether the app links it.

| Package | Version | Revision | License | License files at that revision |
| --- | --- | --- | --- | --- |
| [swift-nio](https://github.com/apple/swift-nio) | 2.101.3 | `0b18836bd8b0` | Apache-2.0 | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-nio/0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b/LICENSE.txt), [NOTICE.txt](https://raw.githubusercontent.com/apple/swift-nio/0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b/NOTICE.txt) |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | 0.15.0 | `3ec281496f28` | Apache-2.0 | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-nio-ssh/3ec281496f28a3b6581afd946b759e2642f5cd8d/LICENSE.txt) |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.1 | `47d3869a7291` | Apache-2.0 | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-crypto/47d3869a7291f085c1fb9fb1e6d3b97a793f45c6/LICENSE.txt), [NOTICE.txt](https://raw.githubusercontent.com/apple/swift-crypto/47d3869a7291f085c1fb9fb1e6d3b97a793f45c6/NOTICE.txt) |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.1 | `a9a5efd40eaf` | Apache-2.0 | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-asn1/a9a5efd40eaf558a2bcd48d64b1d1646be686008/LICENSE.txt), [NOTICE.txt](https://raw.githubusercontent.com/apple/swift-asn1/a9a5efd40eaf558a2bcd48d64b1d1646be686008/NOTICE.txt) |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | `0442cb5a3f98` | Apache-2.0 with Runtime Library Exception | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-atomics/0442cb5a3f98ab802acb777929fdb446bda11a34/LICENSE.txt) |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | `a0cb0954ecb2` | Apache-2.0 with Runtime Library Exception | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-collections/a0cb0954ecb21e4e31b0070e6ed5674e8556685a/LICENSE.txt) |
| [swift-system](https://github.com/apple/swift-system) | 1.8.0 | `704705c5c511` | Apache-2.0 with Runtime Library Exception | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-system/704705c5c51156ede21172a38654d522ce487074/LICENSE.txt) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | `6a52f3251125` | Apache-2.0 with Runtime Library Exception | [LICENSE.txt](https://raw.githubusercontent.com/apple/swift-argument-parser/6a52f3251125d74daf04fcbd5e6f08a75d074382/LICENSE.txt) |
| [SwiftTerm](https://github.com/cunderw/SwiftTerm), a fork of [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | none. Pinned by revision. It is upstream v1.18.0 plus two commits | `96771c0ea228` | MIT | [LICENSE](https://raw.githubusercontent.com/cunderw/SwiftTerm/96771c0ea228df36583daf71c1e17698e41efb67/LICENSE) |

SwiftTerm is pinned to the `cunderw/SwiftTerm` fork because of two changes. The fork's commit
`f56f0f0f7f69` has the upstream `v1.18.0` commit `7691f85b222a` as its only parent and changes
one file. That change is open upstream as
[migueldeicaza/SwiftTerm#659](https://github.com/migueldeicaza/SwiftTerm/pull/659). The fork's
commit `96771c0ea228` has `f56f0f0f7f69` as its only parent and changes one source file and
one test file. It refuses the kitty graphics media that name a file or a shared memory object
on the device. Upstream's `main` branch refuses them by default, and no upstream tag has that
yet.

### Apache License 2.0

This is the license of swift-nio, swift-nio-ssh, swift-crypto, swift-asn1, swift-atomics,
swift-collections, swift-system and swift-argument-parser. The text below is
`LICENSE.txt` of swift-nio at `0b18836bd8b0`. The `LICENSE.txt` files of the other seven
packages have the same Apache text. They differ in leading whitespace and in the blank lines
at the end, and four of them add the exception that follows this section. That was checked
with `diff -w -B`.

```text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

### Runtime Library Exception to the Apache License 2.0

swift-atomics, swift-collections, swift-system and swift-argument-parser add this exception
after the Apache text in their `LICENSE.txt`. The paragraph is the same in all four. The
text below is from swift-atomics at `0442cb5a3f98`.

```text
## Runtime Library Exception to the Apache 2.0 License: ##


    As an exception, if you use this Software to compile your source code and
    portions of this Software are embedded into the binary product as a result,
    you may redistribute such product without providing attribution as would
    otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
```

### NOTICE files

Apache License section 4(d) asks for the `NOTICE` file of a work to travel with it. Three of
the packages have one. Each text below is the whole `NOTICE.txt` of that package at the
revision named in the table above.

#### swift-nio `NOTICE.txt`

```text

                            The SwiftNIO Project
                            ====================

Please visit the SwiftNIO web site for more information:

  * https://github.com/apple/swift-nio

Copyright 2017, 2018 The SwiftNIO Project

The SwiftNIO Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product is heavily influenced by Netty.

  * LICENSE (Apache License 2.0):
    * https://github.com/netty/netty/blob/4.1/LICENSE.txt
  * HOMEPAGE:
    * https://netty.io

---

This product contains NodeJS's llhttp.

  * LICENSE (MIT):
    * https://github.com/nodejs/llhttp/blob/1e1c5b43326494e97cf8244ff57475eb72a1b62c/LICENSE-MIT
  * HOMEPAGE:
    * https://github.com/nodejs/llhttp

---

This product contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's uSHET

  * LICENSE (MIT):
    * https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/lib/cpp_magic.h
  * HOMEPAGE:
    * https://github.com/18sg/uSHET

---

This product contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project)

  * LICENSE (BSD-3):
    * https://opensource.org/licenses/BSD-3-Clause
  * HOMEPAGE:
    * https://github.com/freebsd/freebsd-src

---

This product contains a derivation of Fabian Fett's 'Base64.swift'.

  * LICENSE (Apache License 2.0):
    * https://github.com/swift-extras/swift-extras-base64/blob/b8af49699d59ad065b801715a5009619100245ca/LICENSE
  * HOMEPAGE:
    * https://github.com/fabianfett/swift-base64-kit

---

This product contains a derivation of "XCTest+AsyncAwait.swift" & "StructuredConcurrencyHelpers" from AsyncHTTPClient.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swift-server/async-http-client

---

This product contains a derivation of "_TinyArray.swift" from SwiftCertificates.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-certificates

---

This product contains a derivation of the mocking infrastructure from Swift System.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-system

---

This product contains a derivation of "TokenBucket.swift" from Swift Package Manager.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swiftlang/swift-package-manager
```

#### swift-crypto `NOTICE.txt`

```text
                            The SwiftCrypto Project
                            =======================

Please visit the SwiftCrypto web site for more information:

  * https://github.com/apple/swift-crypto

Copyright 2019 The SwiftCrypto Project

The SwiftCrypto Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product contains test vectors from Google's wycheproof project.

  * LICENSE (Apache License 2.0):
    * https://github.com/C2SP/wycheproof/blob/31387e2cd596587c859c611027b6a44d2e2b65ff/LICENSE
  * HOMEPAGE:
    * https://github.com/google/wycheproof

---

This product contains a derivation of various files from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio
```

#### swift-asn1 `NOTICE.txt`

```text

                            The SwiftASN1 Project
                            =====================

Please visit the SwiftASN1 web site for more information:

  * https://github.com/apple/swift-asn1

Copyright 2022 The SwiftASN1 Project

The SwiftASN1 Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

---

This product contains derivations of various scripts from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio
    
---

This product contains derivations of various scripts from Swift OpenAPI Generator.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-openapi-generator
```

### SwiftTerm: MIT License

The text below is `LICENSE` of `cunderw/SwiftTerm` at `96771c0ea228`. It names four
copyright holders, which are the four first lines.

```text
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Fonts

The four files in [`Driverr/Fonts`](Driverr/Fonts) are one font family, JetBrains Mono NL
Nerd Font Mono, in Regular, Bold, Italic and Bold Italic.

| Part | Version | License | Source |
| --- | --- | --- | --- |
| JetBrains Mono NL | 2.304 | SIL Open Font License 1.1 | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono/tree/v2.304) at tag `v2.304`. The NL files are in `fonts/ttf` there |
| Nerd Fonts patch | 3.5.1 | Patched fonts: SIL Open Font License 1.1. Nerd Fonts source code: MIT | [ryanoasis/nerd-fonts](https://github.com/ryanoasis/nerd-fonts/tree/v3.5.1) at tag `v3.5.1` |

The version strings are read from the `name` table of
`JetBrainsMonoNLNerdFontMono-Regular.ttf`. Name ID 5 reads
`Version 2.304; ttfautohint (v1.8.4.7-5d5b);Nerd Fonts 3.5.1`. Name ID 0 reads
`Copyright 2020 The JetBrains Mono NL Project Authors (https://github.com/JetBrains/JetBrainsMonoNL)`.
Name ID 7 reads `JetBrains Mono is a trademark of JetBrains s.r.o.`
The URL in name ID 0 returned HTTP 404 on 2026-10-07. The NL files are in the
JetBrainsMono repository linked in the table.

[`Driverr/Fonts/OFL.txt`](Driverr/Fonts/OFL.txt) is the license text that ships with the
fonts. It names `The JetBrains Mono Project Authors` and not `The JetBrains Mono NL Project
Authors`.

Nerd Fonts' [`LICENSE`](https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.5.1/LICENSE) at `v3.5.1` says
that its source code files are MIT, with `Copyright (c) 2014 Ryan L McIntyre`, and that its
patched fonts are OFL 1.1, with `Copyright (c) 2014, Ryan L McIntyre (https://ryanlmcintyre.com)`.

### Nerd Fonts glyph sets

[`license-audit.md`](https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.5.1/license-audit.md) at tag
`v3.5.1` lists these glyph sources and their licenses. The patcher can add glyphs from any
of them. The `cmap` table of each of the four Driverr files has code points in the target
range of each of these 13 sets, with the ranges read from `font-patcher` at `v3.5.1`. That
shows the sets are present by code point range. It does not show which glyph came from which
source. The upstream, version
and license columns are from
[`src/glyphs/README.md`](https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.5.1/src/glyphs/README.md)
at the same tag. Where the two Nerd Fonts files give a different license for one set, both are shown.

| Glyph set | License in `license-audit.md` | Upstream | Version | License in `src/glyphs/README.md` |
| --- | --- | --- | --- | --- |
| Codicons | CC BY 4.0 | https://github.com/microsoft/vscode-codicons | 0.0.45 | CC BY 4.0 |
| Devicons | MIT | https://github.com/devicons/devicon | 2.17.0 | MIT |
| Font Awesome | CC BY 4.0 | https://github.com/FortAwesome/Font-Awesome | 6.5.1 | CC BY 4.0 |
| Font Awesome Extension | MIT | https://github.com/AndreLZGava/font-awesome-extension | 0.0.3 | MIT |
| Font Logos | Unlicensed | https://github.com/lukas-w/font-logos | 1.3.0 | unlicensed |
| IEC Power Symbols (README name: Power Symbols IEC) | MIT | https://github.com/jloughry/Unicode | Feb 2015 | MIT |
| Material Design Icons (README name: MaterialDesign) | Apache 2.0 | https://github.com/Templarian/MaterialDesign-Font | Oct 6, 2022 | Apache 2.0 |
| Original Source (Seti-UI but modified) | MIT | https://github.com/jesseweed/seti-ui | 0.8.1 | MIT |
| Octicons | MIT | https://github.com/primer/octicons | 18.3.0 | MIT |
| Pomicons | SIL OFL 1.1 | https://github.com/gabrielelana/pomicons | 1.001 | OFL 1.1 RFN |
| Powerline Extra Symbols | MIT | https://github.com/ryanoasis/powerline-extra-symbols | 1.200 | MIT |
| Powerline Symbols | Free License | https://github.com/powerline/powerline | 1.000 (ca 2013) | MIT |
| Weather Icons | SIL OFL 1.1 | https://github.com/erikflowers/weather-icons | 2.0.10 (1.100) | OFL 1.1 |

`src/glyphs/README.md` also lists `extraglyphs` from
[source-foundry/Hack](https://github.com/source-foundry/Hack), license MIT, which
`license-audit.md` does not list.

"Unlicensed" for Font Logos is Nerd Fonts' label. The `LICENSE` of
[lukas-w/font-logos](https://github.com/lukas-w/font-logos) at
[`v1.3.0`](https://raw.githubusercontent.com/lukas-w/font-logos/v1.3.0/LICENSE) is The Unlicense,
a public domain dedication.

Codicons and Font Awesome are CC BY 4.0, which asks for attribution and a link to the
license: <https://creativecommons.org/licenses/by/4.0/>. Nerd Fonts keeps license files for
some of the sets in [`src/glyphs`](https://github.com/ryanoasis/nerd-fonts/tree/v3.5.1/src/glyphs)
at `v3.5.1`.

## Theme palettes

The colour values of the bundled themes were transcribed from the sources below. No code was
copied. The theme definitions are in
[`DriverrKit/Sources/DriverrCore/Theme.swift`](DriverrKit/Sources/DriverrCore/Theme.swift).
The license files named here were read from the default branch of each repository on the
commit shown.

| Theme | Source | License | Copyright line in that license file |
| --- | --- | --- | --- |
| Solarized | [altercation/solarized](https://github.com/altercation/solarized), commit `62f656a02f93` | MIT, `LICENSE` | `Copyright (c) 2011 Ethan Schoonover` |
| Nord, dark half. The light half is Driverr's own | [nordtheme/nord](https://github.com/nordtheme/nord), commit `1cef71605416` | MIT, `license` | `Copyright (c) 2016-present Sven Greb <development@svengreb.de> (https://www.svengreb.de)` |
| Tokyo Night and Tokyo Night Day | [folke/tokyonight.nvim](https://github.com/folke/tokyonight.nvim), `extras/kitty`, commit `cdc07ac78467` | Apache-2.0, `LICENSE` | None. The file is the Apache text with the template line `Copyright [yyyy] [name of copyright owner]` |
| Catppuccin Mocha and Latte | [catppuccin/alacritty](https://github.com/catppuccin/alacritty), commit `f6cb5a5c2b40` | MIT, `LICENSE` | `Copyright (c) 2021 Catppuccin` |
| Gruvbox | [morhetz/gruvbox-contrib](https://github.com/morhetz/gruvbox-contrib), `xresources`, commit `150e9ca30fcd` | `gruvbox-contrib` has no license file. The README of [morhetz/gruvbox](https://github.com/morhetz/gruvbox) at commit `ef8864bb42bf`, which has none either, says under License: `MIT/X11` | None |
| Dracula and Alucard | ANSI colours from [spec.draculatheme.com](https://spec.draculatheme.com). Surface, foreground and cursor from [dracula/alacritty](https://github.com/dracula/alacritty), commit `c8a3a13404b7` | MIT. The text is `LICENSE` of dracula/alacritty. No license text was found on the spec site's page | `Copyright (c) 2018 Dracula Theme` in dracula/alacritty. [dracula/dracula-theme](https://github.com/dracula/dracula-theme) at `e22ebcc048b8` has `Copyright (c) 2023 Dracula Theme` |
| One Dark, dark half | [alacritty/alacritty-theme](https://github.com/alacritty/alacritty-theme), `themes/one_dark.toml`, commit `ab88d5a80d67` | Apache-2.0, `LICENSE` | `Copyright 2019-2023 indrajit` and `Copyright 2023-     The Alacritty Project` |
| One Dark hues and One Light | [atom/one-dark-syntax](https://github.com/atom/one-dark-syntax), commit `9c96f4454362`, and [atom/one-light-syntax](https://github.com/atom/one-light-syntax), commit `d84579027410`. Both repositories are archived | MIT, `LICENSE.md` | `Copyright (c) 2016 GitHub Inc.` in both |

Nord's license file names a maintainer address. It is copied as it is published.

## Test fixtures and interoperability strings

The repository holds short pieces of text that other products write, because Driverr has to
read them.

- **herdr.** `terminal attach failed: terminal <id> already has an attached client; retry with
  --takeover` is the message [herdr](https://github.com/herdrdev/herdr) sends when it refuses a
  second client on a terminal. `DriverrKit/Sources/DriverrHerdr/TerminalBridge.swift` matches
  part of it. `DriverrKit/Tests/DriverrHerdrTests/TerminalBridgeTests.swift` and
  `DriverrTests/TerminalSceneModelTests.swift` hold it as test input. herdr's `LICENSE` file is
  the Apache License 2.0, read at commit `2563803dca97`.
- **Claude Code.** `PaneScreenFixtures.swift` and `PaneQuestionScreenFixtures.swift` in
  `DriverrKit/Tests/DriverrCoreTests` hold terminal screens of Claude Code, which is a product
  of Anthropic. `DriverrKit/Sources/DriverrHerdr/FakeControl.swift` holds one more screen, a
  question picker. The interface text in them is as Claude Code drew it, except for the words
  that the header of `PaneScreenFixtures.swift` lists as edited.
  `DriverrKit/Sources/DriverrCore/PaneQuestionScreen.swift` matches the picker's last line,
  which starts `Enter to select`. `Driverr/AppEnvironment.swift` holds two messages that
  Claude Code writes when a session stops, a usage-limit message and an API error message, and
  `DriverrKit/Sources/DriverrCore/AgentStop.swift` quotes them in a comment. The sentence that
  starts `Your questions have been answered` in
  `DriverrKit/Sources/DriverrTranscript/FakeTranscriptHost.swift` and
  `DriverrKit/Tests/DriverrTranscriptTests/Fixture.swift` is the one Claude Code writes into a
  session file. Other tests under `DriverrKit/Tests` repeat these strings. This file gives no
  license text for Claude Code.

## App icon

The app icon, `Driverr/Assets.xcassets/AppIcon.appiconset/icon-1024.png`, is AI-generated
artwork. It is not third-party material.
