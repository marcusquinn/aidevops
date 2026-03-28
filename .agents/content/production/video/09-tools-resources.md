# Related Tools & Resources

## Internal References

- `.agents/tools/video/video-prompt-design.md` — Veo 3 Meta Framework (7-component prompting)
- `.agents/video/higgsfield.md` — Higgsfield API integration
- `.agents/video/heygen-skill.md` — HeyGen Avatar API (talking-head generation)
- `.agents/video/muapi.md` — MuAPI (VEED lipsync, face swap, VFX)
- `.agents/tools/video/remotion.md` — Programmatic video editing
- `.agents/tools/voice/voice-models.md` — TTS model comparison (ElevenLabs, MiniMax, Qwen3-TTS)
- `.agents/tools/voice/qwen3-tts.md` — Qwen3-TTS setup and voice cloning
- `.agents/content/production/image.md` — Image generation (Nanobanana Pro, Midjourney, Freepik)
- `.agents/content/production/audio.md` — Voice pipeline, 4-Layer Audio Design
- `.agents/content/production/characters.md` — Character consistency (Facial Engineering, Character Bibles)
- `.agents/content/optimization.md` — A/B testing, seed bracketing automation
- `.agents/scripts/seed-bracket-helper.sh` — Seed bracketing CLI

## Helper Scripts

```bash
# Seed bracketing
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"
seed-bracket-helper.sh list    # Show all bracket runs
seed-bracket-helper.sh status  # Check progress of latest run
seed-bracket-helper.sh score 4005 8 9 7 8 9 && seed-bracket-helper.sh report

# Unified video generation CLI (Sora 2, Veo 3.1, Nanobanana Pro)
video-gen-helper.sh generate sora "A cat reading a book" sora-2-pro 8 1280x720
video-gen-helper.sh generate veo "Cinematic mountain sunset" veo-3.1-generate-001 16:9
video-gen-helper.sh character /path/to/face.jpg
video-gen-helper.sh bracket "Product demo" https://example.com/product.jpg 4000 4010 dop-turbo
video-gen-helper.sh status sora vid_abc123 && video-gen-helper.sh download sora vid_abc123 ./output
video-gen-helper.sh models
```

## External Resources

- [Sora 2 Documentation](https://openai.com/sora)
- [Veo 3.1 Documentation](https://deepmind.google/technologies/veo/)
- [Higgsfield Platform](https://platform.higgsfield.ai)
- [HeyGen Platform](https://www.heygen.com/)
- [Topaz Video AI](https://www.topazlabs.com/topaz-video-ai)
