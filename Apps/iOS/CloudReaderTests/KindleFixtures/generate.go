// Run `go run .` from this directory to recreate rich-kf8-image-links.azw3.
package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"log"
	"os"

	"github.com/behringer24/azw3"
)

func main() {
	book := azw3.New()
	book.SetUniqueID(2026102101)
	book.SetTitle("灯塔与潮汐 / The Lantern and the Tide")
	book.AddAuthor("CloudReader Fixture Authors")
	book.AddDescription("Original English and Chinese sample text written for CloudReader Kindle decoder tests.")
	if err := book.AddLanguage("zh-Hans"); err != nil {
		log.Fatal(err)
	}

	style := `body { font-family: serif; } h1 { text-align: center; } .note { color: #31536b; }`
	if _, err := book.AddStylesheet("fixture-style", style); err != nil {
		log.Fatal(err)
	}
	imageID, err := book.AddImage("beacon-illustration", beaconJPEG())
	if err != nil {
		log.Fatal(err)
	}
	chapterOne := `<h1>第一章：灯光</h1><p>At the edge of the bay, Lin lit the beacon as evening fell.</p>` +
		`<p>海风穿过松林，潮水慢慢升起。</p><p><img src="` + string(imageID) + `" alt="A small lighthouse over the bay"/></p>` +
		`<p><a href="#tide-note">Read the note about the tide.</a></p>`
	if _, err := book.AddChapter("chapter-one", "第一章：灯光", chapterOne, 0); err != nil {
		log.Fatal(err)
	}
	chapterTwo := `<h1>第二章：潮汐</h1><p id="tide-note" class="note">The tide turns beneath the moon. 月亮升起时，海湾恢复了平静。</p>` +
		`<p>The lamp went dark at dawn, and the boats returned safely.</p>`
	if _, err := book.AddChapter("chapter-two", "第二章：潮汐", chapterTwo, 1); err != nil {
		log.Fatal(err)
	}

	path := "rich-kf8-image-links.azw3"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if err := book.Write(path); err != nil {
		log.Fatal(err)
	}
	// azw3 v0.5.2 writes the current time to the PalmDB header. Fix all
	// three Palm timestamps so repeated runs produce identical bytes.
	data, err := os.ReadFile(path)
	if err != nil {
		log.Fatal(err)
	}
	if len(data) < 78 {
		log.Fatal("generated PalmDB header is truncated")
	}
	const fixedPalmTimestamp = uint32(3_900_000_000)
	for _, offset := range []int{36, 40, 44} {
		binary.BigEndian.PutUint32(data[offset:offset+4], fixedPalmTimestamp)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		log.Fatal(err)
	}
}

func beaconJPEG() []byte {
	const width, height = 32, 40
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, color.RGBA{R: 220, G: 239, B: 248, A: 255})
		}
	}
	ink := color.RGBA{R: 34, G: 57, B: 72, A: 255}
	gold := color.RGBA{R: 242, G: 173, B: 63, A: 255}
	for y := 14; y < 35; y++ {
		for x := 13; x < 20; x++ {
			img.Set(x, y, ink)
		}
	}
	for y := 10; y < 14; y++ {
		for x := 11; x < 22; x++ {
			img.Set(x, y, ink)
		}
	}
	for y := 6; y < 10; y++ {
		for x := 14; x < 19; x++ {
			img.Set(x, y, gold)
		}
	}
	for y := 7; y < 10; y++ {
		for x := 5; x < 14; x++ {
			img.Set(x, y, gold)
		}
		for x := 19; x < 28; x++ {
			img.Set(x, y, gold)
		}
	}
	for x := 7; x < 25; x++ {
		img.Set(x, 35, ink)
	}
	buf := new(bytes.Buffer)
	if err := jpeg.Encode(buf, img, &jpeg.Options{Quality: 90}); err != nil {
		log.Fatal(err)
	}
	return buf.Bytes()
}
