#!/usr/bin/env python3
"""zip を EdDSA 署名して docs/appcast.xml に <item> を追加/更新する。

使い方: appcast_add.py <version> <zip_path> <sparkle_tools_dir>
GitHub Releases の zip URL を enclosure に埋め、署名(sign_update)を付与する。
"""
import os
import re
import subprocess
import sys
from email.utils import formatdate

version, zip_path, tools_dir = sys.argv[1], sys.argv[2], sys.argv[3]
APPCAST = "docs/appcast.xml"
REPO = "sagaway3105/claude-bar"

# EdDSA 署名（秘密鍵は Keychain 内。出力は sparkle:edSignature="..." length="..."）
signed = subprocess.check_output([f"{tools_dir}/sign_update", zip_path]).decode()
sig = re.search(r'sparkle:edSignature="([^"]+)"', signed).group(1)
length = re.search(r'length="(\d+)"', signed).group(1)

pub = formatdate(localtime=True)
zip_url = f"https://github.com/{REPO}/releases/download/v{version}/ClaudeBar-v{version}.zip"
release_url = f"https://github.com/{REPO}/releases/tag/v{version}"
notes = (
    f"<h3>ClaudeBar v{version}</h3>"
    f'<p>変更点の詳細は <a href="{release_url}">リリースページ</a> をご覧ください。</p>'
)

item = f"""    <item>
      <title>v{version}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{zip_url}" sparkle:edSignature="{sig}" length="{length}" type="application/octet-stream" />
    </item>"""

content = open(APPCAST).read()
# 同一バージョンの再リリース時は既存アイテムを除去してから差し込む
content = re.sub(
    r"[ \t]*<item>\s*<title>v" + re.escape(version) + r"</title>.*?</item>\n",
    "",
    content,
    flags=re.DOTALL,
)
content = content.replace("    <!-- ITEMS -->", "    <!-- ITEMS -->\n" + item)
open(APPCAST, "w").write(content)
print(f"✅ appcast に v{version} を追加しました")
