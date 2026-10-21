import { MOBI } from './mobi.js'
import { unzlibSync } from './fflate.js'

const MAX_CHAPTERS = 10_000
const MAX_RESOURCE = 16 * 1024 * 1024
const MAX_TOTAL = 128 * 1024 * 1024
const token = () => `kindle-resource:${crypto.randomUUID()}`
const sanitizeMarkup = doc => {
    for (const element of doc.querySelectorAll('script, iframe, frame, object, embed, form, input, video, audio, source')) element.remove()
    for (const element of doc.querySelectorAll('*')) {
        for (const attribute of [...element.attributes]) {
            const name = attribute.name.toLowerCase()
            const value = attribute.value.trim()
            if (name.startsWith('on') || name === 'srcdoc' || name === 'action' || name === 'formaction'
                || (name === 'style' && /url\s*\(\s*["']?(?:https?:|file:|\/\/)/i.test(value))) {
                element.removeAttribute(attribute.name)
                continue
            }
            if (!['src', 'href', 'poster', 'xlink:href'].includes(name)) continue
            if (element.localName === 'a' && name === 'href') {
                if (/^(?:filepos:|kindle:pos:)/i.test(value) || /^[a-z][a-z\d+.-]*:/i.test(value)) element.removeAttribute(name)
                else if (!value.startsWith('#') && !/^chapter-[0-9]{5}\.html(?:#[A-Za-z0-9_.%~-]+)?$/.test(value)) element.removeAttribute(name)
            } else if (/^(?:data:|blob:|https?:|file:|javascript:|\/\/)/i.test(value)) {
                if (!value.startsWith('data:image/') && !value.startsWith('kindle-resource:')) element.removeAttribute(name)
            } else if (value && !value.startsWith('#') && !value.startsWith('kindle-resource:')) element.removeAttribute(name)
        }
    }
    return doc
}

window.kindler = {
    cancelled: false,
    cancel() { this.cancelled = true },
    async convert(base64) {
        this.cancelled = false
        const binary = atob(base64)
        const bytes = Uint8Array.from(binary, c => c.charCodeAt(0))
        let totalOutput = 0
        const resources = new Map()
        const warnings = []
        const originalWarn = console.warn
        console.warn = (...args) => warnings.push(args.map(String).join(' '))
        const originalCreate = URL.createObjectURL.bind(URL)
        let book
        URL.createObjectURL = blob => {
            const key = token()
            resources.set(key, blob)
            return key
        }
        try {
            const mobi = new MOBI({ unzlib: data => unzlibSync(data) })
            book = await mobi.open(new File([bytes], 'book.mobi', { type: 'application/octet-stream' }))
            if (!book.sections?.length || book.sections.length > MAX_CHAPTERS)
                throw new Error('Invalid chapter count')
            const docs = []
            for (const section of book.sections) {
                if (this.cancelled) throw new DOMException('Cancelled', 'AbortError')
                if (section.linear === 'no') continue
                const sectionURL = await section.load()
                const blob = resources.get(sectionURL)
                if (!blob) throw new Error('Parser did not return a local section')
                const source = await blob.text()
                resources.delete(sectionURL)
                totalOutput += new TextEncoder().encode(source).byteLength
                if (totalOutput > MAX_TOTAL) throw new Error('Output is too large')
                const doc = new DOMParser().parseFromString(source, 'text/html')
                if (doc.body?.textContent?.trimStart().startsWith('%MOP'))
                    throw new Error('UNSUPPORTED_KINDLE_FORMAT')
                docs.push({ source, doc, title: doc.querySelector('title')?.textContent?.trim(), sectionID: section.id })
            }
            if (!docs.length) throw new Error('No readable chapters')

            const chapterByLink = new Map()
            for (const { doc } of docs) {
                if (this.cancelled) throw new DOMException('Cancelled', 'AbortError')
                for (const link of doc.querySelectorAll('a[href]')) {
                    const href = link.getAttribute('href') || ''
                    if (!/^(?:filepos:|kindle:pos:)/i.test(href)) continue
                    try {
                        const target = await book.resolveHref(href)
                        const targetIndex = docs.findIndex(chapter => chapter.sectionID === target?.index)
                        if (!target || targetIndex < 0) continue
                        const targetDoc = docs[targetIndex].doc
                        const node = target.anchor(targetDoc)
                        const id = node?.id || node?.getAttribute('name') || node?.getAttribute('aid')
                        if (id) chapterByLink.set(href, `chapter-${String(targetIndex + 1).padStart(5, '0')}.html#${encodeURIComponent(id)}`)
                    } catch {}
                }
            }

            const output = []
            for (let index = 0; index < docs.length; index++) {
                if (this.cancelled) throw new DOMException('Cancelled', 'AbortError')
                const { doc, title } = docs[index]
                for (const element of doc.querySelectorAll('a[href]')) {
                    const href = element.getAttribute('href') || ''
                    if (chapterByLink.has(href)) element.setAttribute('href', chapterByLink.get(href))
                }
                sanitizeMarkup(doc)
                // Keep generated resources in the manifest; native code validates and writes them.
                const html = '<!doctype html>' + doc.documentElement.outerHTML
                totalOutput += new TextEncoder().encode(html).byteLength
                if (totalOutput > MAX_TOTAL) throw new Error('Output is too large')
                output.push({ path: `Text/chapter-${String(index + 1).padStart(5, '0')}.html`, title: title || `Chapter ${index + 1}`, html })
            }
            const exported = []
            let resourceIndex = 0
            for (const [key, blob] of resources) {
                if (this.cancelled) throw new DOMException('Cancelled', 'AbortError')
                if (blob.size > MAX_RESOURCE) throw new Error('A resource is too large')
                totalOutput += blob.size
                if (totalOutput > MAX_TOTAL) throw new Error('Output is too large')
                const bytes = new Uint8Array(await blob.arrayBuffer())
                const prefix = new TextDecoder().decode(bytes.slice(0, 256)).trimStart().toLowerCase()
                const sniffed = bytes[0] === 0xff && bytes[1] === 0xd8 ? 'image/jpeg'
                    : bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 ? 'image/png'
                    : prefix.startsWith('gif8') ? 'image/gif'
                    : prefix.startsWith('<svg') || prefix.startsWith('<?xml') && prefix.includes('<svg') ? 'image/svg+xml'
                    : prefix.startsWith('<!doctype html') || prefix.startsWith('<html') ? 'text/html'
                    : prefix.startsWith('@charset') || prefix.includes('{') && /[.#][\w-]+\s*\{/.test(prefix) ? 'text/css'
                    : 'application/octet-stream'
                const type = !blob.type || blob.type === 'application/octet-stream' ? sniffed : blob.type
                if (!/^[\w.+-]+\/[\w.+-]+$/.test(type)) throw new Error('Invalid resource media type')
                let binary = ''
                for (let offset = 0; offset < bytes.length; offset += 0x8000)
                    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000))
                const base64 = btoa(binary)
                const path = `Resources/resource-${String(++resourceIndex).padStart(5, '0')}`
                const extension = ({ 'image/jpeg': '.jpg', 'image/png': '.png', 'image/gif': '.gif', 'image/svg+xml': '.svg', 'text/css': '.css', 'application/xhtml+xml': '.xhtml', 'text/html': '.html' })[type] || ''
                exported.push({ key, path: path + extension, type, base64 })
            }
            const paths = new Map(exported.map(resource => [resource.key, resource.path]))
            for (const resource of exported) {
                if (['text/css', 'image/svg+xml', 'application/xhtml+xml', 'text/html'].includes(resource.type)) {
                    let text = new TextDecoder().decode(Uint8Array.from(atob(resource.base64), c => c.charCodeAt(0)))
                    if (resource.type === 'text/css') {
                        text = text.replace(/@import\s+[^;]+;?/gi, '').replace(/url\(\s*["']?(?:https?:|file:|javascript:|\/\/)[^)]*\)/gi, 'none')
                    } else {
                        const parsed = new DOMParser().parseFromString(text, resource.type)
                        text = sanitizeMarkup(parsed).documentElement.outerHTML
                    }
                    for (const [key, path] of paths) text = text.replaceAll(key, path.split('/').pop())
                    resource.base64 = btoa(Array.from(new TextEncoder().encode(text), b => String.fromCharCode(b)).join(''))
                }
            }
            for (const chapter of output) {
                for (const [key, path] of paths) chapter.html = chapter.html.replaceAll(key, '../' + path)
                // External and unresolved resource references are stripped.
                chapter.html = chapter.html.replace(/\s(?:src|href|poster|xlink:href)=["'](?:https?:|file:|javascript:|\/\/)[^"']*["']/gi, '')
            }
            return { title: docs[0].title || null, chapters: output, resources: exported, warnings }
        } finally {
            console.warn = originalWarn
            URL.createObjectURL = originalCreate
            try { book?.destroy?.() } catch {}
        }
    }
}
