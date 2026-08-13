import Testing
@testable import TurboCode

@Suite("Chat Markdown presentation")
struct ChatMarkdownPresentationTests {
    @Test("Decorative headings and checkmark bullets become quiet structure")
    func cleansDecorativeModelFormatting() {
        let markdown = """
        ## 🔗 Dependencies
        - ✅ Streaming
          - ☑️ Nested verification
        ### ⚠️ Notes
        """

        #expect(
            ChatMarkdownPresentation.cleaned(markdown) == """
            ## Dependencies
            - [x] Streaming
              - [x] Nested verification
            ### Notes
            """
        )
    }

    @Test("Prose and fenced examples remain byte-for-byte equivalent")
    func preservesMeaningfulContentAndCode() {
        let markdown = """
        A bug 🐛 in prose stays visible.

        ```markdown
        ## 🔗 Example heading
        - ✅ Example item
        ```

        - Ordinary item
        """

        #expect(ChatMarkdownPresentation.cleaned(markdown) == markdown)
    }
}
