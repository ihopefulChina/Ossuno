import Testing
@testable import Ossuno

struct FinderChromeTests {
    @Test func pathAndTransferBarsShareAFinderStatusHeight() {
        #expect(FinderChrome.barHeight == 24)
    }

    @Test func transferTrayTitlePrefersActiveCount() {
        #expect(TransferTrayStatus.title(activeCount: 1, totalCount: 214) == "正在传输 1 项")
        #expect(TransferTrayStatus.title(activeCount: 0, totalCount: 214) == "传输 · 214 项")
        #expect(TransferTrayStatus.title(activeCount: 0, totalCount: 0) == "传输")
    }
}
