import qrcode
from PIL import Image
import os

# Data to be encoded
data = "https://csatraining.mooo.com/phish"

# Logo to be added
logo_path = 'csa_logo.png'
if not os.path.exists(logo_path):
    print(f"Error: {logo_path} not found.")
    exit(1)

logo = Image.open(logo_path)

# Adjust logo size (QR code is usually 300-500px, 100px for logo is fine for High error correction)
# Calculate the max size for the logo (approx 20-30% of QR)
# For version 10 with box_size 10, the QR image is around 370px.
# We'll use a version higher than 1 to ensure enough space.

# Create QR Code
qr = qrcode.QRCode(
    version=5, # Higher version for more space
    error_correction=qrcode.constants.ERROR_CORRECT_H,
    box_size=10,
    border=4,
)
qr.add_data(data)
qr.make(fit=True)

# Create image from QR Code
qr_img = qr.make_image(fill_color="black", back_color="white").convert('RGB')

# Resize logo to fit nicely in the middle
qr_width, qr_height = qr_img.size
logo_size = qr_width // 4 # Use 25% of QR width
logo.thumbnail((logo_size, logo_size), Image.Resampling.LANCZOS)

# Create a white background for the logo to mask the QR bits behind it
# (optional but looks cleaner)
logo_bg = Image.new("RGBA", (logo.width + 10, logo.height + 10), (255, 255, 255, 255))
logo_bg_pos = ((qr_width - logo_bg.width) // 2, (qr_height - logo_bg.height) // 2)
qr_img.paste(logo_bg, logo_bg_pos)

# Calculate position for logo
pos = ((qr_width - logo.width) // 2, (qr_height - logo.height) // 2)

# Paste logo
# If logo doesn't have alpha, we just paste it.
if logo.mode == 'RGBA':
    qr_img.paste(logo, pos, logo)
else:
    qr_img.paste(logo, pos)

# Save the final image
output_path = 'phish_qr_code.png'
qr_img.save(output_path)
print(f"QR Code with logo saved as {output_path}")
