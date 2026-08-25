# MDock Preview

Xem trước cửa sổ trực tiếp khi rê chuột lên biểu tượng trên Dock của macOS —
giống hành vi thanh taskbar của Windows. Rê chuột lên một app trong Dock, một
bảng nổi sẽ hiện ảnh thu nhỏ của từng cửa sổ; bấm vào ảnh để chuyển sang cửa sổ
đó, hoặc ✕ để đóng. App còn có **bộ chuyển cửa sổ** đầy đủ (kiểu ⌘Tab). Chạy như
một tiện ích trên thanh menu, không chiếm ô trên Dock.

## Yêu cầu

- macOS 14 trở lên
- Hai quyền (**Cài đặt Hệ thống › Quyền riêng tư & Bảo mật**), được xin ngay lần
  mở đầu qua màn hình Chào mừng:
  - **Trợ năng (Accessibility)** — theo dõi con trỏ trên Dock + chuyển/đóng cửa sổ
  - **Ghi màn hình (Screen Recording)** — tạo ảnh thu nhỏ của cửa sổ

## Tính năng

- Xem trước khi rê chuột, bấm để chuyển, đóng từng cửa sổ
- **Bộ chuyển cửa sổ**: giữ phím tắt + Tab để lướt qua mọi cửa sổ đang mở (Tab /
  Shift+Tab để chuyển, thả ra để chọn, hoặc bấm vào ô). Phím tắt chọn sẵn —
  **⌘Tab** (thay trình chuyển ứng dụng của hệ thống, mặc định), **⌥Tab**, hoặc
  **⌃Tab**
- Chủ đề preview: System · Graphite · Frost · Vibrant
- Khởi động cùng hệ thống, tùy chọn ẩn biểu tượng thanh menu
- Tiếng Anh + Tiếng Việt

## Build từ mã nguồn

Cần Xcode 26+ và [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project MDockPreview.xcodeproj -scheme MDockPreview -configuration Release build
```

Hoặc mở `MDockPreview.xcodeproj` bằng Xcode rồi bấm Run.

## Bản phát hành (DMG đã ký)

Build bản Release universal, ký Developer ID, notarize + staple app, rồi tạo ảnh
cài đặt có giao diện:

```bash
Scripts/make-dmg.sh   # cần app đã build, ký, notarize & staple sẵn trong dist/
```

`Scripts/make-dmg.sh` vẽ nền ([`create-dmg-background.swift`](Scripts/create-dmg-background.swift)),
sắp xếp cửa sổ kéo-thả vào Applications và icon ổ đĩa, rồi ký, notarize và staple
DMG. Script dùng profile notarytool `MFinderNotary` trong keychain.

## Ghi chú

Dùng API riêng `_AXUIElementGetWindow` (giống AltTab / yabai) nên được phân phối
dưới dạng app ký Developer ID, đã notarize, **ngoài Mac App Store**. macOS giữ
⌘Tab cho trình chuyển của hệ thống; app chặn phím thật để thay thế — nếu máy bạn
không đè được, hãy chuyển sang ⌥Tab trong Cài đặt.

Được tạo với ❤️ cho Maclife & Đồng Bọn.
