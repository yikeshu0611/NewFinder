import Foundation

enum OfficeDocumentStubs {
    /// Minimal valid OOXML packages (ZIP) for newly created Office files.

    private static let xlsxBase64 =
        "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"

    private static let docxBase64 =
        "UEsDBBQAAAAIAPq2H10XmADX6wAAALIBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnht" +
        "bH1QyU4DMQy98xWRr2gmAweEUKc9sByBQ/kAK/HMRM2mOC3t3+NpoQdUONpvs99i" +
        "tQ9e7aiwS7GHm7YDRdEk6+LYw8f6pbkHxRWjRZ8i9XAghtXyarE+ZGIl4sg9TLXm" +
        "B63ZTBSQ25QpCjKkErDKWEad0WxwJH3bdXfapFgp1qbOHiBmTzTg1lf1vJf96ZJC" +
        "nkE9nphzWA+Ys3cGq+B6F+2vmOY7ohXlkcOTy3wtBNCXI2bo74Qf4ZuUU5wl9Y6l" +
        "vmIQmv5MxWqbzDaItP3f58KlaRicobN+dsslGWKW1oNvz0hAF88f6GPlyy9QSwME" +
        "FAAAAAgA+rYfXT+t/vqvAAAALAEAAAsAAABfcmVscy8ucmVsc43POw7CMAwA0J1T" +
        "RN5pWgaEUEMXhNQVlQNEiZtWNB/F4dPbk4EBKgZG/57tunnaid0x0uidgKoogaFT" +
        "Xo/OCLh0p/UOGCXptJy8QwEzEjSHVX3GSaY8Q8MYiGXEkYAhpbDnnNSAVlLhA7pc" +
        "6X20MuUwGh6kukqDfFOWWx4/DVigrNUCYqsrYN0c8B/c9/2o8OjVzaJLP3YsOrIs" +
        "o8Ek4OGj5vqdLjILPJ/Dv548vABQSwMEFAAAAAgA+rYfXVVduLfZAAAARwEAABEA" +
        "AAB3b3JkL2RvY3VtZW50LnhtbEVQwW7DIAy99ysQ9xWyVVEWJemtt0mTtn0ABTeJ" +
        "FDACd1n39QO6Kpfn9+wnP8vd8ccu7BtCnNH1vNpLzsBpNLMbe/71eXpqOIuknFEL" +
        "Ouj5DSI/DrtubQ3qqwVHLG1wsV17PhH5VoioJ7Aq7tGDS7MLBqsoyTCKFYPxATXE" +
        "mALsIp6lrIVVs+Nl5xnNbUjVZwgZaOjEA0NBX5wRNL0Xhx8/ftma86vqVdY88Snx" +
        "unlpuLgb3lRIXUKf+oeDzJYwjxNt8oxEaDe9wOUxFSX1P2+X+f1Ksb1g+ANQSwEC" +
        "FAMUAAAACAD6th9dF5gA1+sAAACyAQAAEwAAAAAAAAAAAAAAgAEAAAAAW0NvbnRl" +
        "bnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAIAPq2H10/rf76rwAAACwBAAALAAAAAAAA" +
        "AAAAAACAARwBAABfcmVscy8ucmVsc1BLAQIUAxQAAAAIAPq2H11VXbi32QAAAEcB" +
        "AAARAAAAAAAAAAAAAACAAfQBAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAAAwAD" +
        "ALkAAAD8AgAAAAA="

    private static let pptxBase64 =
        "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" +
        "c42PsQ7CMAxEd74i8k7SMiCECCwICYkJlQ+wEreNaJMoThH9ezICYmA8+/zOtzs8" +
        "x0E8KLELXkMtKxDkTbDOdxpuzWm5AcEZvcUheNIwE8Nhv9hdacBcbrh3kUWBeNbQ" +
        "5xy3SrHpaUSWIZIvmzakEXORqVMRzR07UquqWqv0zoAvqDhbDelsaxDNHOkfeGhb" +
        "Z+gYzDSSzz8yFA/O0gXnMOWCxdRR1iDl+/zDVMsSAaq8pj4K719QSwMEFAAAAAgA" +
        "+rYfXZQkIWs5AQAAdQIAACEAAABwcHQvc2xpZGVMYXlvdXRzL3NsaWRlTGF5b3V0" +
        "MS54bWyNUstuwyAQvOcrEPcGp4eqsuJE6vPSNpGSfgDF69gqLy3Etf++gG25lXLI" +
        "BdjZmWF3Yb3tlCQtoGuMLuhqmVECWpiy0aeCfh5fbu4pcZ7rkkujoaA9OLrdLNY2" +
        "d7J84705exIstMt5QWvvbc6YEzUo7pbGgg65yqDiPoR4YiXyn2CtJLvNsjumeKPp" +
        "qMdr9KaqGgFPRpwVaD+YIEjuQ/mubqyb3Ow1bhbBBZuk/l+S721o9kty/U1JomEb" +
        "gBVNrYuDLInmKiAPibKJ87BHBEh53b6iPdg9Rlx8tHskTRnVo4iyMTHSUqjbdGB/" +
        "5dHsNFnxvKtQxT1MgXQFDW/Vx5VFDDpPxACKGRX17gJX1M8X2Gy6gM2XLmIwdhaP" +
        "sfNhBBLfud21qa4wXg/4mCAbnndoY6YMLtN/2fwCUEsDBBQAAAAIAPq2H13k1H8K" +
        "tQAAADgBAAAsAAAAcHB0L3NsaWRlTGF5b3V0cy9fcmVscy9zbGlkZUxheW91dDEu" +
        "eG1sLnJlbHONj7EOwjAMRHe+IvJO0jIghAhdEBIDCyofYCVuG9EmURwQ/D0ZC2Jg" +
        "PPv8zrdrntMoHpTYBa+hlhUI8iZY53sN1/a43IDgjN7iGDxpeBFDs1/sLjRiLjc8" +
        "uMiiQDxrGHKOW6XYDDQhyxDJl00X0oS5yNSriOaGPalVVa1VmjPgCypOVkM62RpE" +
        "+4r0Dzx0nTN0COY+kc8/MhSPztIZOVMqWEw9ZQ1SzucfplqWCFDlNfVReP8GUEsD" +
        "BBQAAAAIAPq2H12qbUyfpQEAAHUDAAAhAAAAcHB0L3NsaWRlTWFzdGVycy9zbGlk" +
        "ZU1hc3RlcjEueG1sjZPJbuwgEEX3/RWIfYLb7fRLrLazeGOkTMrwATTgQcGAgPi5" +
        "/z4FNpmURTZwOVRdqMLenU+DRKOwrteqwuvjDCOhmOa9aiv8+PDn6BQj56niVGol" +
        "KnwQDp/Xq50pneRX1HlhEVgoV9IKd96bkhDHOjFQd6yNULDXaDtQD0vbEm7pf7Ae" +
        "JMmzbEsG2iu85Nvv5Oum6Zn4pdnzIJSfTayQ1MP1Xdcbl9zMd9yMFQ5sYvaHK8UC" +
        "2b3kNcz7dh7vRIN6PkGXsmyN6x0to7X4KS0aqazwvl1jUu/IEryouVnmwQoRpRr/" +
        "WnNvbm1wZdfjrQVXMMVI0QE6HCzixhIWl2qMgrxPD2ZtsqLl1NghzNAiBJeEhzyE" +
        "kQQmJo/YDNkbZd3NF7Gs+/1FNEkHkLdDV2GxVBZkbFjsnLRX1CDoR4Wlh8r8BIo/" +
        "gdq3eWB5YHlgoChj8AoQsYhE8kReYzaJbBIpEikSOUnkJJFtIluMOtmrJ/g2woRR" +
        "o+W/GSQFtS4f9yU96Gd/wS+drz+S+F75uvhRnG62xRlGtgzEXvD0/p/SVwub/5f6" +
        "BVBLAwQUAAAACAD6th9dS9m/CMsAAADAAQAALAAAAHBwdC9zbGlkZU1hc3RlcnMv" +
        "X3JlbHMvc2xpZGVNYXN0ZXIxLnhtbC5yZWxzrZBNasMwEIX3PYWYfSU7ixJKlGxK" +
        "IZBVSQ4wSGNb1JaEZhLq21cki8alhS66GZif973HbHYf06guVDikaKHVDSiKLvkQ" +
        "ewun4+vjGhQLRo9jimRhJobd9mHzRiNK1fAQMqsKiWxhEMnPxrAbaELWKVOsmy6V" +
        "CaW2pTcZ3Tv2ZFZN82TKPQO+QdXeWyh734I6zpn+Ak9dFxy9JHeeKMoPHobH4OmA" +
        "czpLxWLpSSxofT9fHLW6WoD5JdrqP6NJ1dIi1HVyq185zOLx209QSwMEFAAAAAgA" +
        "+rYfXTaTRqsQAwAAmg0AABQAAABwcHQvdGhlbWUvdGhlbWUxLnhtbM1XTXObMBC9" +
        "51dodE/4MDjYE5yJHTM9tNOZxp2eZRAfjRAM0iTxv6+EDBEGaqdx2vqA0Wrfe9pd" +
        "aWXf3L7kBDzhimUF9aF1ZUKAaVhEGU18+H0TXHoQMI5ohEhBsQ93mMHbxcUNmvMU" +
        "5xgIOGVz5MOU83JuGCwUZsSuihJTMRcXVY64GFaJEVXoWdDmxLBNc2rkKKMQUJQL" +
        "1q9xnIUYbCQlfGVfE/GgnNWWkFQPYa2pY5R39GgtxBfbsRWpwBMiPhRSUfG8wS8c" +
        "AoIYFxM+NOsPNBY3hgJJMOEjYA0Y1J89UAKUql0Dq2TbIq3AmV3ftwr2XqHvuF6v" +
        "V2urZVSOKAxFvFbP2Qk8a9mwNk6vgD77ynRNpwvQFSY9wGy5XLqzDmCiAZwewDOn" +
        "zp3dATgawO3HsLxbraYdgKsBpj1AcD2bOl3AtAakJKOPPXdZ2bZEykU6xwX5NOjv" +
        "CX+v2Qut14UctVttz0D56M7L0c+iCoSH5CeIZxTwXYljFArHFSLZtsqkBppjpM0o" +
        "U8gOTIZOWNNn9Mz0LeGFiruJTYWaj0caZ4Q88B3Bn5laGytIFgXCWqe2hrXJLVPx" +
        "upd89ZOopEL1AFQF/5Hx9CFFpVCyoGRJWEOeMFAWTFQVjrLLCZEQrmxuc7KFN+Jf" +
        "ikiZJ/qJb2nqUcI6ShPJcKra5PqdapbyPFHOcofl3N/LGU1G5eYRWwfJpm5NbaUN" +
        "WIgIjmTuFUNTmg+tk2VqhUpRhAfMWojWkRD/NKPum1ZhH6nriYk2+4k2Bg4WoQdD" +
        "8CwatGu7EISo9GEsGoF4zUtByWgCASKJuLxDroI8fi4Pop4N7y7LdMeC7kiUFeP3" +
        "iKUKVU811xrVArBdR+biPBEcdpbTlzHxrH+5DKNXXhzHOORjpkU7FJOKR5/9WG9j" +
        "cHXbJPi/rwJn5Co4ayvRzo890jTc0fPTaxol4imQD7H7siokuNaQnWFTfBMFAG3L" +
        "AtyHl556rVrjViza08KTVH+vp3sjCT/rbaglfPL+Lv22hLsD+XaPpNsYOCmG9hNL" +
        "DQ//5zSmxS9QSwECFAMUAAAACAD6th9dY4P/eSUBAADXAwAAEwAAAAAAAAAAAAAA" +
        "gAEAAAAAW0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAIAPq2H11XzWjfsAAA" +
        "AC8BAAALAAAAAAAAAAAAAACAAVYBAABfcmVscy8ucmVsc1BLAQIUAxQAAAAIAPq2" +
        "H13XCR77AgEAAAUCAAAUAAAAAAAAAAAAAACAAS8CAABwcHQvcHJlc2VudGF0aW9u" +
        "LnhtbFBLAQIUAxQAAAAIAPq2H12TnrPB0gAAAEACAAAfAAAAAAAAAAAAAACAAWMD" +
        "AABwcHQvX3JlbHMvcHJlc2VudGF0aW9uLnhtbC5yZWxzUEsBAhQDFAAAAAgA+rYf" +
        "Xe7DV6geAQAAQgIAABUAAAAAAAAAAAAAAIABcgQAAHBwdC9zbGlkZXMvc2xpZGUx" +
        "LnhtbFBLAQIUAxQAAAAIAPq2H13QczgotQAAADgBAAAgAAAAAAAAAAAAAACAAcMF" +
        "AABwcHQvc2xpZGVzL19yZWxzL3NsaWRlMS54bWwucmVsc1BLAQIUAxQAAAAIAPq2" +
        "H12UJCFrOQEAAHUCAAAhAAAAAAAAAAAAAACAAbYGAABwcHQvc2xpZGVMYXlvdXRz" +
        "L3NsaWRlTGF5b3V0MS54bWxQSwECFAMUAAAACAD6th9d5NR/CrUAAAA4AQAALAAA" +
        "AAAAAAAAAAAAgAEuCAAAcHB0L3NsaWRlTGF5b3V0cy9fcmVscy9zbGlkZUxheW91" +
        "dDEueG1sLnJlbHNQSwECFAMUAAAACAD6th9dqm1Mn6UBAAB1AwAAIQAAAAAAAAAA" +
        "AAAAgAEtCQAAcHB0L3NsaWRlTWFzdGVycy9zbGlkZU1hc3RlcjEueG1sUEsBAhQD" +
        "FAAAAAgA+rYfXUvZvwjLAAAAwAEAACwAAAAAAAAAAAAAAIABEQsAAHBwdC9zbGlk" +
        "ZU1hc3RlcnMvX3JlbHMvc2xpZGVNYXN0ZXIxLnhtbC5yZWxzUEsBAhQDFAAAAAgA" +
        "+rYfXTaTRqsQAwAAmg0AABQAAAAAAAAAAAAAAIABJgwAAHBwdC90aGVtZS90aGVt" +
        "ZTEueG1sUEsFBgAAAAALAAsALgMAAGgPAAAAAA=="

    static var xlsx: Data {
        guard let data = Data(base64Encoded: xlsxBase64), !data.isEmpty else {
            preconditionFailure("OfficeDocumentStubs.xlsx base64 decode failed")
        }
        return data
    }

    static var docx: Data {
        guard let data = Data(base64Encoded: docxBase64), !data.isEmpty else {
            preconditionFailure("OfficeDocumentStubs.docx base64 decode failed")
        }
        return data
    }

    static var pptx: Data {
        guard let data = Data(base64Encoded: pptxBase64), !data.isEmpty else {
            preconditionFailure("OfficeDocumentStubs.pptx base64 decode failed")
        }
        return data
    }
}
