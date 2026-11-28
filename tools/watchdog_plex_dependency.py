"""Executed inside a producer: config + authenticated Plex metadata only; no media I/O."""
import json
import os
from pathlib import Path
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import yaml


def main():
    profile, mode, hint = sys.argv[1:4]
    if profile == 'kometa':
        path = Path(hint or os.environ.get('KOMETA_CONFIG', '/config/config.yml'))
    else:
        base = Path('/config')
        path = base / 'config.yml'
        if not path.exists():
            choices = [base / (name + '.yml') for name in ('kometa', 'plex') if (base / (name + '.yml')).exists()]
            selected = base / (os.environ.get('RUN_MODE', '') + '.yml')
            if selected in choices:
                path = selected
            elif len(choices) == 1:
                path = choices[0]
            elif len(choices) > 1:
                raise ValueError('Ambiguous producer configuration')
    config = {}
    if path.exists():
        if path.stat().st_size > 2 * 1024 * 1024:
            raise ValueError('Producer configuration exceeds bounded reader')
        config = yaml.safe_load(path.read_text()) or {}
    plex = config.get('plex', {})
    url, token = plex.get('url'), plex.get('token')
    if profile == 'metafusion':
        url, token = os.environ.get('PLEX_URL', url), os.environ.get('PLEX_TOKEN', token)
    if not isinstance(url, str) or not isinstance(token, str) or not token:
        raise ValueError('Plex endpoint/credential unavailable')
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('Plex endpoint is not a safe HTTP origin/path')
    target = urllib.parse.urlunsplit((parsed.scheme.lower(), parsed.netloc.lower(), parsed.path.rstrip('/'), '', ''))
    libraries = config.get('libraries', {}) if profile == 'kometa' else {}
    if not isinstance(libraries, dict) or (profile == 'kometa' and not libraries):
        raise ValueError('No configured libraries')
    for library in libraries.values():
        if not isinstance(library, dict):
            raise ValueError('Invalid library configuration')
        override = library.get('plex') or {}
        if override.get('url', url).rstrip('/') != url.rstrip('/') or override.get('token', token) != token:
            raise ValueError('Multiple Plex targets/credentials require explicit review')
    output = {'schema': 1, 'target': target, 'configuration': str(path), 'verified': False}
    if mode == 'config':
        return output

    class SameOrigin(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            other = urllib.parse.urlsplit(newurl)
            if (other.scheme.lower(), other.netloc.lower()) != (parsed.scheme.lower(), parsed.netloc.lower()):
                raise ValueError('Cross-origin redirect prohibited')
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    # Disable environment proxies; retain default TLS verification and never
    # return a token, raw response, exception text or media filesystem path.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), SameOrigin())

    def read(endpoint):
        request = urllib.request.Request(target + endpoint, headers={'X-Plex-Token': token, 'Accept': 'application/xml'})
        with opener.open(request, timeout=5) as response:
            data = response.read(1024 * 1024 + 1)
            if response.status != 200 or len(data) > 1024 * 1024:
                raise ValueError('Invalid bounded Plex response')
        return ET.fromstring(data)

    identity, sections = read('/identity'), read('/library/sections')
    machine = identity.get('machineIdentifier')
    titles = {item.get('title') for item in sections.findall('Directory')}
    if not machine or not titles or (libraries and not set(libraries).issubset(titles)):
        raise ValueError('Plex identity/library selection unverified')
    return dict(output, verified=True, machineIdentifier=machine, libraryCount=len(titles))


try:
    print(json.dumps(main(), separators=(',', ':')))
except Exception:
    print(json.dumps({'schema': 1, 'verified': False, 'reason': 'Producer Plex configuration or authenticated identity/library check is unverified'}))
    sys.exit(1)
