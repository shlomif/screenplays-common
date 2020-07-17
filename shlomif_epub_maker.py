#! /usr/bin/env python3
# -*- coding: utf-8 -*-
# vim:fenc=utf-8
#
# Copyright © 2020 Shlomi Fish <shlomif@cpan.org>
#
# Distributed under the MIT license.

xmlns1 = "urn:oasis:names:tc:opendocument:xmlns:container"
medtype1 = "application/oebps-package+xml"
EPUB_CONTAINER = ('''<?xml version="1.0"?>
<container version="1.0" xmlns="{xmlns1}">
    <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="{medtype1}"/>
    </rootfiles>
</container>''').format(medtype1=medtype1, xmlns1=xmlns1)


doctype = \
    ('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"' +
     ' "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">')
htmlstart = \
    ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:xsi=' +
     '"http://www.w3.org/2001/XMLSchema-instance" xml:lang="en" >')
imgpref = '''<p class="center"><img id="coverimage" src="'''

EPUB_COVER = '''<?xml version="1.0" encoding="UTF-8"?>
{doctype}
{htmlstart}
<head>
<title>{esc_title}</title>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<link rel="stylesheet" type="text/css" href="style.css" />
<style type="text/css">
body {{
{tab}margin: 0;
{tab}padding: 0;
}}
img#coverimage {{
{tab}max-width: 100%;
{tab}padding: 0;
{tab}margin: 0;
}}
</style>
</head>
<body>

<!-- Generated file, modifying it is futile. -->

{imgpref}{cover_image_fn}" alt="{esc_title}" /></p>

</body>
</html>'''


def _my_amend_epub(filename, json_fn):
    from glob import glob
    from zipfile import ZipFile, ZIP_STORED
    import html
    import json
    z = ZipFile(filename, 'a')
    with open(json_fn, 'rb') as fh:
        j = json.load(fh)
    images = set()
    htmls = set()
    for html_src in ['cover.html']:
        z.writestr(
            'OEBPS/' + html_src,
            EPUB_COVER.format(
                imgpref=imgpref, tab="\t", htmlstart=htmlstart,
                cover_image_fn=j['cover'],
                doctype=doctype,
                esc_title=html.escape(j['title'])),
            ZIP_STORED)
    for item in j['contents']:
        if 'generate' not in item:
            item['generate'] = (item['type'] == 'toc')
        if item['generate']:
            continue
        html_src = item['source']
        if item['type'] == 'text' and '*' in html_src:
            html_sources = sorted(glob(html_src))
        else:
            html_sources = [html_src]
        for html_src in html_sources:
            htmls.add(html_src)
            with open(html_src, 'rt') as fh:
                text = fh.read()
            from bs4 import BeautifulSoup
            soup = BeautifulSoup(text, 'lxml')
            for img in soup.find_all('img'):
                src = img['src']
                if src:
                    images.add(src)
    z.writestr("mimetype", "application/epub+zip", ZIP_STORED)
    z.writestr("META-INF/container.xml", EPUB_CONTAINER, ZIP_STORED)
    z.write("style.css", "OEBPS/style.css", ZIP_STORED)
    for img in sorted(list(images)):
        z.write(img, 'OEBPS/' + img)
    for html_src in sorted(list(htmls)):
        z.write(html_src, 'OEBPS/' + html_src, ZIP_STORED)
    z.close()
