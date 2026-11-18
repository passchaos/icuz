#!/usr/bin/env python3
"""Verify committed Unicode generators and generated artifacts.

This check needs no external UCD checkout. It validates binary headers and
layout, pins artifact/generator SHA-256 values, and checks provenance embedded
in the committed generated Zig table. Generator reruns that need upstream UCD
files remain optional build dependencies of `unicode-verify`.
"""

from __future__ import annotations

import hashlib
import re
import struct
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UNICODE_VERSION = (17, 0, 0)


@dataclass(frozen=True)
class Blob:
    path: str
    magic: bytes
    format_version: int
    sha256: str
    version: tuple[int, int, int] = UNICODE_VERSION


@dataclass(frozen=True)
class GeneratedText:
    path: str
    generator: str
    sha256: str


BLOBS = (
    Blob("src/unicode/bidi/conformance.bin", b"CJBT", 1, "40d4b9145779f8aad815e1f5ea5201ccd9cc5daeb73c8bf73b06c6f1c76d9a26"),
    Blob("src/unicode/bidi/data.bin", b"CJB1", 1, "9e9f9937100d6019f7308743916c3606bdb31c9cc4f142eb605becf45a210c3f"),
    Blob("src/unicode/canonical/combining_class.bin", b"CJC1", 1, "336130546fc300108806f5ae23144cda93da13488a810946357304b5a12f5fcc"),
    Blob("src/unicode/charset/data.bin", b"CJCS", 1, "965bd7d7e6084e49d6a5a04f350807c0c2cdeececeacfa78103d928f45f71575"),
    Blob("src/unicode/transliterate/data.bin", b"CJTR", 12, "166e6197576ca36f683a6d22eb790ee4886a14ad9cf70087fd37c325e6bf9fbf", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/georgian_bgn_conformance.bin", b"CJTG", 1, "e8d6ea181123ec5175c7b4d92e1591febcdc9ea0ee2800d075e5bbd4f81acf62", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/hebrew_bgn_conformance.bin", b"CJTH", 1, "c8e0869ef80a3608d0d98f8d07f291e3863a4c7d6b08bf3bd50fe7242459af51", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/russian_bgn_conformance.bin", b"CJRU", 1, "bd90c67fe72c02a91305a394c3506158d1b2fd39d307ec57838df20594d2e6e2", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/greek_bgn_conformance.bin", b"CJGR", 1, "298f3587347fb597658a56b73ffef0f30db8254484f2396cfc857b814ab65917", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/katakana_bgn_conformance.bin", b"CJKA", 1, "b8adb92773ce7f5d0923c452dc6f44bf9d7527798fbcc15b5a1e163f6ec1a8a2", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/amharic_bgn_conformance.bin", b"CJAM", 1, "5a8a9db44cd49d7feadb9b14dd0366aa9e798ce795dbee3f1d695e3a4a6050ec", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kazakh_bgn_conformance.bin", b"CJKZ", 1, "cb80e89d0e949e92a4b8aad9b7a0d3148866ae1fd87b1c0f53a703f110b794de", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/turkmen_bgn_conformance.bin", b"CJTM", 1, "f3199b793df346060d42ed7a85f390c4795b8ecf198de6bf00c459fbbdd7f025", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/ukrainian_bgn_conformance.bin", b"CJUA", 1, "b8c31aab7c9655a333b1cbb18216da3ffd54ecfe282d079cacb71a612127f161", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/belarusian_bgn_conformance.bin", b"CJBY", 1, "3bbc7bc142b9b9d6a8c8d3915c6738aaac4c6c611ed4cc9c9578865620d4eb09", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/mongolian_bgn_conformance.bin", b"CJMO", 1, "e7050df752dccfa88c2389dce705268ecd2ae4a4df8b5602d06e246327547e13", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bulgarian_bgn_conformance.bin", b"CJBU", 1, "2d726f1d199d30be7808dbdcf0be90c8f4cee346eb7c84e9d9d631e8a09898ff", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/macedonian_bgn_conformance.bin", b"CJMC", 1, "9aac301a11088b723c13958f6a67e9acf14c157c8b8a8f3ec76b15b73a8aa700", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/serbian_bgn_conformance.bin", b"CJRS", 1, "dd13f5af11b2b41b7c49f3214cb27278f7cbcd9b6ebc34d30e9f315eb4e732a7", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/sgw_ethi_conformance.bin", b"CJSG", 1, "58d6d7bf5e28587ce30ea0e3274ac45d3a5196007058607dee8926e0eafc44fa", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/amharic_geminate_conformance.bin", b"CJGE", 1, "ec00beeee7461e2f643d6fb9838dbb93ff0e6f922e955175e69a739d8df9b8c6", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/ethi_aethiopi_conformance.bin", b"CJE3", 1, "0c48d7e3e2a5fc1716d7f7a0b5555a319f9ca2ed067800f7b4451eb9b20101d1", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/ethi_beta_conformance.bin", b"CJE4", 1, "d5a4dea05f26129487c89ce2e607e52881035deb6fec08a838bbad945db912bc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/ethi_ies_conformance.bin", b"CJE5", 1, "e71753079a4fbcd57c87953d58cdbd6ad7557ff5fbeb9f9eeba85f1d10345e3a", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/byn_tekie_conformance.bin", b"CJBK", 1, "3533bc9c7c3ce1edeab189e17ec6efc9fda318e835ae8f64b3985b853fb8e736", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/ethi_lambdin_conformance.bin", b"CJE7", 1, "9891196f6cac1bbde150e909e4264b1ab3d89d608346d796828e043afcc7763e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/si_latn_conformance.bin", b"CJSL", 1, "02df63e40429e25e0e78339a463a99ba38a0e3b772fd6aa4205a6c3f27b89db4", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/my_fonipa_conformance.bin", b"CJMF", 1, "8cf621c4a774b4dadc4a9004c50dae6bcc278bfbf1e84771335acde73e2f9389", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/byn_xaleget_conformance.bin", b"CJB2", 1, "e2a1047ecac5a540adaff36631958870c0dbb5308597177c848a72d049a364f3", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/cyrillic_latin_conformance.bin", b"CJYL", 1, "562a14357cbc58cc860888ad0fb96c845f4399e446c0567dc96021e1805d55a2", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/arabic_latin_icu_conformance.bin", b"CJAL", 1, "eda3bb451374312d1c859c16ca1c2905dc92cec9514d023e734f7c3aba7e5aac", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_arabic_conformance.bin", b"CJIA", 1, "726a2568363029aff4b5bcff23de65df3f91d0cd39feec9a83cec390b67a00c0", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_deva_conformance.bin", b"CJDE", 1, "e6196a83a9b82cf677cac9c47b481454b8dfeea39a2ed6289795ced65b700a28", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_beng_conformance.bin", b"CJIB", 1, "99233d3656ba9572bb8b79ae8fc5a85d584cd35fd789b8af91e796cf51ecfadb", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_guru_conformance.bin", b"CJIG", 1, "ee79fd79ca339c29013c3b2647e6609f9b2098b6f8ebbc7324c3d71462e617fc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_gujr_conformance.bin", b"CJIU", 1, "e909a77962281be314cd8ab365a0c637cff7a2f456c839df4a5f8e8e925b13b3", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_orya_conformance.bin", b"CJIO", 1, "384ee60f7a6b0f55760213ad069260a77ef24e611422de8b2259cb667b38dae8", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_telu_conformance.bin", b"CJIE", 1, "09d0d89963e12f1e96ae8516d1b8172c8b2a3f0df6898386a63c2522edce293d", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_knda_conformance.bin", b"CJIK", 1, "695c04f1b3d7bcb32dccf64d49eb35670bac822a4d1307276c9fcadfd195fadd", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_mlym_conformance.bin", b"CJIM", 1, "4a9dc2a666e1725961d2c8827a93390007ac2f5194486529aac9a539b07bbe45", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_latn_conformance.bin", b"CJIX", 1, "5dd064763619ef2d5570c7b59d50d395d5888d58e53168636c8a20eb9a660b85", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/chr_fonipa_conformance.bin", b"CJCH", 1, "27b6f5b488b13f413b6d4636db51ab79a4ce4e7a025f44d448c13e7df721ae50", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/zu_fonipa_conformance.bin", b"CJZU", 1, "3ac662c95da35652e532d0dce0d5e3cf8fcf2f13478cfa57ba6cea94e93505a8", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kk_fonipa_conformance.bin", b"CJKK", 1, "6e52fdca711ef8f5886eb3ed662be66a7e9af10e0244e0a10bcb350c115bfaf6", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/interindic_taml_conformance.bin", b"CJTA", 1, "b6aaa89588666e4dd5fa2a2220bd149b2f0da7e3f3428dc0c190a273528b059e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/hiragana_katakana_conformance.bin", b"CJHK", 1, "e2df9ac14e6f474db52a291167ceaa5af0d7d160e3b4f8ff4a25eae5c62c22f9", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/persian_bgn_conformance.bin", b"CJPE", 1, "de7abad6ff72cf8e0d62983e8b5aca665e3bc41ad530fcb3abea9658d49ed19c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/nv_fonipa_conformance.bin", b"CJN2", 1, "44e1b698946effd050931bfb134c18d6a417480fbb1c2fed91db53172af73605", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/si_fonipa_conformance.bin", b"CJSF", 1, "2df242a0be990f7537577dd8f0b4d0b51ae7d18e505e7162fd43dc70e4c22dd1", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/es_fonipa_conformance.bin", b"CJEF", 1, "9bb3b2ccfdd73849fb3707f91127308ad20dfd3cc0cbbd094e79e4f948ae5974", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/xh_fonipa_conformance.bin", b"CJHF", 1, "69372303943163330ccee97091e9375fd13305b378a046c76d499c8cfc1964ba", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/vec_fonipa_conformance.bin", b"CJVF", 1, "dd9b742cd19f403c530c2b257ea1d0dbe1264280d8f1471c03e32acf8d905b41", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/ro_fonipa_conformance.bin", b"CJOF", 1, "c0505682135deffea1d7e96eea7dd24502c58d2f66fb39fcf190cbad6a52003e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/arabic_bgn_conformance.bin", b"CJAB", 1, "e84c8658779bf2eeb18aa56d742a59bfdcb62ec8d1a39c0f2a284ee58ca4f6f4", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/armenian_bgn_conformance.bin", b"CJHA", 1, "0889c6ee539d69dd4a186fe237b2883117cf1a11b15dacc661c61743f285c09a", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/thaana_latin_conformance.bin", b"CJTN", 1, "33e0de0539f8bd2fc4d6e3abc101c167167938456013e4739cc3b351305ef540", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/syriac_latin_conformance.bin", b"CJSY", 1, "d99465b90170a2e80bf38e578a4af558221d32aa245a52efe2de068b47844c21", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/canadian_latin_conformance.bin", b"CJCA", 1, "bc13d78890637d4d907dc74d268cde97e8fefd8e2358197bcdf60e587aab3e30", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tr_lower_conformance.bin", b"CJT2", 1, "7b040aaeaf0d88120f5a88aa8e2c63b3d2a3f2e894146649f3fde0593f840c4f", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/az_lower_conformance.bin", b"CJAZ", 1, "f19add06a709f7ee220eef3c7c7e59897b2912d6563c725d7dc4b59f53e09a39", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/el_lower_conformance.bin", b"CJEL", 1, "5549dad504e75ac1d8a13f11d8180081d91e4889ead6da21bfe2fdd6e12d26a5", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/el_upper_conformance.bin", b"CJEU", 1, "673288c1ec552646d6aabbeffac09c33ef3525b2a2c222065415150aa83944e9", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/lt_lower_conformance.bin", b"CJLL", 1, "8f3fb156047faba562ef29ab1095371f049b640b2a009e0d12c28933db3c762b", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/lt_upper_conformance.bin", b"CJLU", 1, "c37ed4f65c24f3e62f4f4832c15a9c4442ec11c52a99b42fe48651fdbb5752dc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/korean_bgn_conformance.bin", b"CJKO", 1, "f8f2891cc1da8d9fcb47353c5950959d4f796c1a51f66dbe621933bfa79ae24e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kirghiz_bgn_conformance.bin", b"CJKI", 1, "cb8b2d0883609810c45361bcf824bd58e588acf1aa34c51d87377a0d8caee5bc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_armenian_conformance.bin", b"CJLA", 1, "79872ddff27fa5bec72f0f6a7dd74c33a7b97aee2b9634cf1b9dd853f9ae19be", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/azerbaijani_bgn_conformance.bin", b"CJA2", 1, "ca0f0e84062f5824012d95eb71235a0082ac5ef97e4b9760f79eeec5f03f6388", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_cyrillic_conformance.bin", b"CJLC", 1, "dbdc4b80e74df2b2792e290e6c48b096acc73795142e6c0f99265526872deafb", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_thaana_conformance.bin", b"CJTT", 1, "4d79ea549917e0581d51884eaadb19e041c17e3a0aeee548fff9312c85af6db2", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_canadian_conformance.bin", b"CJC2", 1, "f407bfea6495a75b53f4b71f5d21aad34195670d3be4cfc4e00952f6f44520d5", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/georgian_latin_conformance.bin", b"CJGG", 1, "eee6c30a86b3b12647ad8f718dcf65f1283c42863a17c95ccb61732dcd60f4b1", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_georgian_conformance.bin", b"CJG3", 1, "6ce65461875f4a193ebf84a37f8c282b32749557034b2bbcae81ed9e1d9d48f5", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/halfwidth_conformance.bin", b"CJHW", 1, "bd2e9bff51c484f6e9aa2a05c00e948c5cc4818c82ff2e4028f78de5e7337d7f", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/fullwidth_conformance.bin", b"CJFW", 1, "82ab47e734fa346624b6813fb44fa1808e055051b69297770ffc12cc919eadfc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_ascii_conformance.bin", b"CJAS", 1, "3e1174a1bf7177c0f46a1d86db2cc794aac714ef9696ebdd074d47c70eb1cf5c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kirghiz_official_conformance.bin", b"CJK3", 1, "55e08829de4d909f654eb48663d66e6bbbaf0a7c360410db48e748825ec90100", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/armenian_official_conformance.bin", b"CJH3", 1, "b15d8e56765be297cad2e3205f6eb433f9a0911b68aeb7b99b5267b73670618f", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/persian_official_conformance.bin", b"CJP3", 1, "69a1af55710adb945120dfbd6525f621423afd7df36de7103233b469c6fcc4ad", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tr_upper_conformance.bin", b"CJTU", 1, "328090249c03e394e5186de28f9aefe95a843e67f9104e5a4d2d6b98dc40af8b", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/az_upper_conformance.bin", b"CJAU", 1, "a484bfe7a9d9ee1be4a1a01f84d7b9b9d884ccda785519417bfc9c828be54440", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/de_ascii_conformance.bin", b"CJD2", 1, "c7444ee2e8e8c9185b3a2397b3737784779d202843af27ddeba9a5bdc0015406", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/any_publishing_conformance.bin", b"CJAP", 1, "c7e43bbfe0b830ebf89ad49c3fc0d483bb88846353b3f82c42e11453ace93d68", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/katakana_hiragana_conformance.bin", b"CJKH", 1, "9fddcd8b970cb546a10056e40d7c8012d21381e9d26036bca083e7ad3dd232f8", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/pashto_bgn_conformance.bin", b"CJPB", 1, "c828178080722b9fbe8de6ffc9a2ab37afd8076219e5a8c08ff62c5e3060a51b", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/simp_trad_conformance.bin", b"CJZ1", 1, "1c1cc544a1bd6256724d9c483860b83c30840d841d6c4355b40933fc918db19b", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/trad_simp_conformance.bin", b"CJZ2", 1, "8ef4b9c3fd59dd2cb21cb5ced58cbf4c05520ad5b3858330c045d00b68e23913", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/de_ascii_official_conformance.bin", b"CJD3", 1, "d9ec3797121f2cffd12b169531ab7d81cf317cf375ea02c233323f84febd56fe", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/hans_hant_conformance.bin", b"CJZ3", 1, "7be3c4963de95654994740cf40d16c32d47b3d86a1ea9c2c93eb6bfaf402e138", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/hant_hans_conformance.bin", b"CJZ4", 1, "72b16bd495bec7474df3e7d37f9785e64e1dcd47b96782ea8c874b5816d6b564", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/eth_gem_aeth_conformance.bin", b"CJEG", 1, "01e92e83c76b4e85c0868b8101235a16111e923348fa9c07f710630643717427", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/eth_gem_ies_conformance.bin", b"CJE6", 1, "4dbc0df749f2820821e1aa79360097f1d701fc875ebfa39ee734cc96dba89fe9", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/my_fonipa_official.bin", b"CJM3", 1, "ceb3536c8c8898ddcb5409295eeffe2f7a03804704bff71d43a60fe4fd4bad01", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/am_fonipa_conformance.bin", b"CJAF", 1, "2e5d56c700ed08a3d772b9601a4510433720aedc7dbd4e9832a972f44de139c7", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/am_fonipa_rev_conformance.bin", b"CJFA", 1, "5dc0b04b212ef8979d54cb94de11764b4ea2e2cb35a9272811a62f1b8bdc689c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kk_am_conformance.bin", b"CJPA", 1, "aa2d618bb102adfc927ccd3b143ce53f74236fb8b39270a38d3ef97fc1c27000", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/my_am_conformance.bin", b"CJPM", 1, "45fee10c7536baac656bef61d9d610777298f7fed93b2f6f9035c29157167ecd", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/ro_am_conformance.bin", b"CJPR", 1, "ed80bd678cb35067a1b0f135cef394d2b85dc107bd7f54945ca92c7ee26cd088", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/si_am_conformance.bin", b"CJPS", 1, "80292b77183e6606786e351926c7f4ed76379713f307116c47c0b50263589ee0", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/xh_am_conformance.bin", b"CJPX", 1, "73fbbdbc421bba3aad8d5221352ade91d6b70b03cbe1602bb9e186bc89cebc2a", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/zu_am_conformance.bin", b"CJPZ", 1, "18e711bef9693dcbce5edf6ab62d8feb9ac510cb540b3e8e957659b174288665", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_arabic_conformance.bin", b"CJLQ", 1, "44eaad6bdedc098041fb5d6fc17ba11c872ce6a8bb31f79976de170c5daf398d", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_syriac_conformance.bin", b"CJLS", 1, "bd19ada921fd14de9913aaf20b82eb51dc8bd5e3f55e6b400aea95243266eca7", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/armenian_latin_conformance.bin", b"CJAR", 1, "857f3a932d2f50ec2a9fb4b8591e36e745386f07fdff68f7188ea3b77b18bd18", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_interindic_conformance.bin", b"CJBI", 1, "5cc71465abc51e68dd17bf0cf57ee8d58dbf87eb1be68c78840d1eba1a797001", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_interindic_conformance.bin", b"CJDI", 1, "be74a5d1cc27e47459d3eac1c277d439dbabdec231221306e1a9b7b69427daef", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_interindic_conformance.bin", b"CJGI", 1, "5279f941f1966d9098cb2de465663decc73c73aea06260153b9576b78f0ce68b", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_interindic_conformance.bin", b"CJUI", 1, "d923d43d88355992ba287b56be2756f703718a365cd12b9cdd595ac571597f7b", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_interindic_conformance.bin", b"CJNK", 1, "faac8bc6eeb733e72c309bae8da1705429cd0dbb9b877a29cb05a43588c30cb5", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_interindic_conformance.bin", b"CJMI", 1, "17d1516d24de26b66f980d57e7a802cdb44a959011d56564ffc9b620d7e065b5", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_interindic_conformance.bin", b"CJRI", 1, "147d5578a260731d8a995090d5bacb7551cba0c6b5dc2949e6b14fe0e2742a47", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_interindic_conformance.bin", b"CJTI", 1, "c7973cf357030a6363bcc1552d4ba9a5d269d039b6f47851024a10a46dd85da4", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_interindic_conformance.bin", b"CJEI", 1, "eb10f3bc5c277568ba486db71f318528a20bb6381d447486c531c10fe6b59360", version=(48, 0, 0)),
    Blob("src/unicode/collation/data.bin", b"CJCL", 2, "3db525f5696955768d63797c465d31285efe0d4cd4db243bd944c178a13f135d"),
    Blob("src/unicode/collation/tailorings.bin", b"CJTL", 4, "800f27cae2d4a13f0618dd57d5475b8cc3f00c705c43ac1f30232bb5430aff96", version=(48, 0, 0)),
    Blob("src/unicode/collation/conformance_non_ignorable.bin", b"CJCT", 1, "46c35a76dc144f13fbd96723a2e676a5561b2739e7bb15d58f193f538ab3841a"),
    Blob("src/unicode/collation/conformance_shifted.bin", b"CJCT", 1, "7ded2b9ed0d456fa69a77b6206d3b64228e5c97e91e5b49d4c61992959e653a5"),
    Blob("src/unicode/grapheme/conformance.bin", b"CJGT", 1, "07053949345b67792108362e7b5146ae2d5467fef9de7fa5e7aa1dd3ddffbd56"),
    Blob("src/unicode/idna/data.bin", b"CJID", 1, "c9bbea4431f770cd977c958c60defba73c8873d2edbc6931a591f7a3f9c6644c", version=(16, 0, 0)),
    Blob("src/unicode/idna/conformance.bin", b"CJIT", 1, "a8c6f27df71c184ab670733b27443340f7c4257bec48c590dbd840e991f49ca9", version=(16, 0, 0)),
    Blob("src/unicode/grapheme/data.bin", b"CJGB", 2, "01f5e5d9197e4b9e779eb3f4540c5f8e4a3ddc9378b9223e81ab8e37cf6f7f5b"),
    Blob("src/unicode/format/plurals_conformance.bin", b"CJPL", 1, "bbae46c2c4f5859bd77e22175aaad6a1fc9ddfc50513094e9235a3b85956f1f6", version=(48, 0, 0)),
    Blob("src/unicode/format/ordinals_conformance.bin", b"CJPL", 1, "e2694b7c8d7a0c196b91445b8e31ca05d4347de7d183b1441d0c8ceaf1ee358d", version=(48, 0, 0)),
    Blob("src/unicode/joining/data.bin", b"CJJ1", 1, "05cf3b4ad489e9012576d26eef615900257c106c56a95bb2969b3e6b62a93af5"),
    Blob("src/unicode/name/data.bin", b"CJNM", 1, "5115bd72b089087be4c814576d81d2b98b0870799ef1c405c38770b3a20f4dbe"),
    Blob("src/unicode/line_break/conformance.bin", b"CJLT", 2, "28e470fb325428ef1cb18b027b8889add6a18f7bf8046e34a986626b687a8ab9"),
    Blob("src/unicode/line_break/data.bin", b"CJL2", 2, "0fef55798282a97581de58698c3617ee0990a52ff40342230fd083f6f881fa92"),
    Blob("src/unicode/normalization/conformance.bin", b"CJNF", 1, "ed9089885715ea3e92f550d0f462e7fa53a681870b95402dc1cae85fd7d17f45"),
    Blob("src/unicode/normalization/quick_check.bin", b"CJQ1", 1, "43650bd3f029bc64fbca0952c2943babd2354cf302a91299583643219a1f701a"),
    Blob("src/unicode/properties/data.bin", b"CJP2", 2, "a7fde8a4eed944cb36af2b2fa8970307989eeca9f6168e0f2b2e69de26450dea"),
    Blob("src/unicode/script/data.bin", b"CJS1", 1, "568090d12531a38659e1e936779464ed05eb3610b443429928fc97eaf119dbdf"),
    Blob("src/unicode/script_extensions/data.bin", b"CJSE", 1, "43135c269af32f24e43b55c94c33205ec715e5f43dddb1ac5b218929e754016b"),
    Blob("src/unicode/sentence/conformance.bin", b"CJST", 1, "ad12cc4dc33a16ffe0da235ac34cb8f0ddfc3c9e85a62c657ee88bb3beeba5cc"),
    Blob("src/unicode/sentence/data.bin", b"CJSB", 1, "c163eb450ba6df51a31fe2ac4a74e3c1d9d154c37ec9124af46dffce6a5844e8"),
    Blob("src/unicode/word/conformance.bin", b"CJWT", 1, "e390fd977570cd63aef4a1c657d4afefa188bfff5e8cc39e60942444feb5b674"),
    Blob("src/unicode/word/data.bin", b"CJWB", 2, "0ed721c08b09aae17c350d1125189b08c912c9fed4610da8704d45a2df4a7000"),
    Blob("src/unicode/word/dictionaries.bin", b"CJDB", 3, "849686cb9bb7eda6b75a96824d6e502b0adf02d0e354d9cbc2a81282bac3bcdb", version=(5, 0, 0)),
    Blob("src/unicode/word/dictionary_conformance.bin", b"CJDW", 1, "5f80f94680dd3d0639a0b342b523ce2129be26942d6eacce96d0b7fab3835f3a", version=(0, 0, 0)),
    Blob("src/unicode/transliterate/bengali_devanagari_conformance.bin", b"CJAC", 1, "719d9cdbdfaa3a0eb328deb496bf1723a9f8279ff368881e027d036fa526f1aa", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_gujarati_conformance.bin", b"CJAD", 1, "5f36e4d50c83a7820f1c37dc5a210ecd0e36bf69ad1f3e3bff7f6535754a9c1c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_gurmukhi_conformance.bin", b"CJAE", 1, "b06c974a0abcf8b9bccc71645b64ccaef914fb57cb7c15fa5e335f8f5f2a2a85", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_kannada_conformance.bin", b"CJAG", 1, "14ff074ca15d51349b6518b1cb751f37393f4f3e118e18eb35bb8d707c9ec7c6", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_latin_conformance.bin", b"CJAH", 1, "9ee2fe441b678db5f9ea7ecbda3f18107700695f01c2c05c6c601ba10e679586", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_malayalam_conformance.bin", b"CJAI", 1, "94b3066736c77957766169d5f6ff7c8361bc00d123d0654383efd1edc5543cff", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_oriya_conformance.bin", b"CJAJ", 1, "481a2aa29d2913374fccf1fb65e81599266d4d2ccf5ea674d00c2215484fbfc7", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_tamil_conformance.bin", b"CJAK", 1, "0e61cbe26882428de99fd4a223a5d9ae1211683cd2c797805fbf76c34250e630", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_telugu_conformance.bin", b"CJAN", 1, "4f222d04a484a4eb028aac8cf8a58522c231a1a7f01cdf0aa4ecd41742e92d9a", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_bengali_conformance.bin", b"CJAT", 1, "997ec2dc1b050033ec0617f622bc557abe3d3df37e3ad0965ea683ea23648791", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_gujarati_conformance.bin", b"CJAV", 1, "0ade57971c17cd291c7a1391e2cc68de2b8ff289ed4cbd26a7e2bac977a3355a", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_gurmukhi_conformance.bin", b"CJAW", 1, "91e1076b3194852b692a7f5cc1e92005c2d605cecc93a13939cd107de4f55bdc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_kannada_conformance.bin", b"CJAX", 1, "c1513d3898da6a89049cbb3a691d3c1b35997696e2c09209e8b50fa0c6ce8289", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_latin_conformance.bin", b"CJAY", 1, "57d31f8d465c14a251a91cb0734be75b0e2fb0853289bcda16b670bf336e8251", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_malayalam_conformance.bin", b"CJA0", 1, "8d49d8bdee528d18a01e7a6bd51aea00ff10188ec821754f9a8a7943a7ea8a0c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_oriya_conformance.bin", b"CJA1", 1, "2d384cc7c876271e742798ef32941a195dae4e78386a698cefbc643fd65c4fbc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_tamil_conformance.bin", b"CJA3", 1, "9ed2caf08e15bdab61dc695bd88859e925053b3115d29c56fc3700b063679189", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_telugu_conformance.bin", b"CJA4", 1, "9ef2b56937f49c72fc1d24d1092e9af6fe985f66aafb56d0846710df9c25f892", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_bengali_conformance.bin", b"CJA7", 1, "a85b8e68e8586fd5378f18d0fcc0b71bbd8409ace755d68024aa088e359a55dc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_devanagari_conformance.bin", b"CJA8", 1, "66a2af40fd913fb53e935e47fd50d8e002a570b783054df073d5712a4ef1ab2b", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_gurmukhi_conformance.bin", b"CJA9", 1, "68f7bf9968ad2c0ae668cc7cccda174795e60310378501577bdbb22461799eef", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_kannada_conformance.bin", b"CJBA", 1, "18829266a0bc41a846bb7850a5a0413d706e9a398fa8a5944bd630a235e03ed4", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_latin_conformance.bin", b"CJBB", 1, "67b48faf2cc0a6b4c7d7d0588fda05563b65667f2353c1b1383a9f5430b7772d", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_malayalam_conformance.bin", b"CJBC", 1, "ca33c6291c976cf927777332f062aa4c53fbce8760a3fbe5b524ae301df958fa", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_oriya_conformance.bin", b"CJBD", 1, "659a4854964d904ad2d10f9212a13efca2591b6f26387e780278e619106bbfd3", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_tamil_conformance.bin", b"CJBE", 1, "caedb28d36e95a8ac4192b8b486558a7af1487e8da349f9de07e7364a0d902f2", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_telugu_conformance.bin", b"CJBF", 1, "6cf642cc4533911e812d1ba1efb2708f7d88f2862faae66a2a40bf3e8599e4f1", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_bengali_conformance.bin", b"CJBJ", 1, "7eedaf8a6112f231c50b935ad6a998b7bfc40bd2641906e37f2d37d3178c38cc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_devanagari_conformance.bin", b"CJBL", 1, "5fc7b341e279f6966683214fb7aa8f0a45102130fb966c932d2e6ec2f45473b6", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_gujarati_conformance.bin", b"CJBM", 1, "72cf8144a836d8bda504296ef4d855b8a474c2711236861c7fc1ca5a94f7cb7c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_kannada_conformance.bin", b"CJBN", 1, "e3537482dd9480c050a6e675d6c9d06e8f94361053aacc81fb1a20e2089a62d0", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_latin_conformance.bin", b"CJBO", 1, "7e5e530b9065a00af98640f18a3871ef4167703f87a10862d1ee649a56ff85ea", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_malayalam_conformance.bin", b"CJBP", 1, "dd31cecf95a72b172e1a2497ed952ba4abeddb39ac87afc46c3e97da1a87bd9d", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_oriya_conformance.bin", b"CJBQ", 1, "b5a3bccda152fd8eae1433e1557c4b900b5f242c3f32ed2f49730b2ed4d48a07", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_tamil_conformance.bin", b"CJBR", 1, "72b6310f4f6016e9f9f80cf4d56627421e0d52a7c241412a5218a33142cba204", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_telugu_conformance.bin", b"CJBS", 1, "53b06954c47bf719bb67633d4d300a824423f768c9aa5778781c2c12083288bc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_bengali_conformance.bin", b"CJBX", 1, "c7aa7306a2a05bf1db92864f0fa5bd099cb9b8beba7eedf9fd8ebd9d4e570b6e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_devanagari_conformance.bin", b"CJBZ", 1, "36352cacb9286d659f4a8da0fee6c73a51be710f1ec15e50e8ec745bb572dc15", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_gujarati_conformance.bin", b"CJB0", 1, "4243bd90a098193721a6498730787e902b6f5365fe1f2e165b993c6f4422a0ef", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_gurmukhi_conformance.bin", b"CJB3", 1, "38c4f9c2a6c8b31980d151f50822ce2c01616d72db53d96b2ed89a5c7ae39403", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_latin_conformance.bin", b"CJB4", 1, "55a7bdf5654ea6bc7095bae8f5459ffda50b8ec1a7af4b36683c231ff93df184", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_malayalam_conformance.bin", b"CJB5", 1, "8ceae4ec93e345e3a8496a92f2e3ef4305fe93dfcb22ee0b44548dd445c3226e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_oriya_conformance.bin", b"CJB6", 1, "e42e02d9213eb690bd7a57e6fba90a091926556a3e9913e2f25cf69871b6dceb", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_tamil_conformance.bin", b"CJB7", 1, "ba0bc187eb63b0ac23861cda5de548843e6309b069420ab39318e67e2507b3c5", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_telugu_conformance.bin", b"CJB8", 1, "84dbe8c9e34204c47c96a736b191058f794d98c204f4aa0e1be1609798e29d0c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_bengali_conformance.bin", b"CJAA", 1, "ac865c0b1c517075e92605330ea9b3d8ab9958c48e942d88192c2d5b9dca7d62", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_devanagari_conformance.bin", b"CJAO", 1, "7cebdc926bddcc664f43aec198e237d7960ddfea00d1ae8c1880345aa9fe2cab", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_gujarati_conformance.bin", b"CJAQ", 1, "d5fe222cf91a949c2bb4f5e03535da105cc16ab80d1d047433b555b99d825737", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_gurmukhi_conformance.bin", b"CJA5", 1, "28600443355bdbc4b42f6894eefba3343f7d59d32c02ad1aea5ad1c597c4a533", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_interindic_conformance.bin", b"CJLI", 1, "e37824e9b28df8ed3264e50396a389732a4861e2951b7427c653ab1823114147", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_kannada_conformance.bin", b"CJA6", 1, "e745d9eb725d0bcb178287b26c44a831bf100e59665111c01240f1085bfcda11", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_malayalam_conformance.bin", b"CJBG", 1, "8372cd98c7912c778a51158a5e41da4f8a0bc1aa7be9d2684f9fb985e715ea0d", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_oriya_conformance.bin", b"CJBH", 1, "13e809821c4963e2133265ecfcdcac6b752a5d549ebd506082945f93a0331069", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_tamil_conformance.bin", b"CJBV", 1, "f27e4ed9e3b56642e9f66904bdfcd9b5f7f5e182c2601c7a8cf5c0e837595b3c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/latin_telugu_conformance.bin", b"CJBW", 1, "01f4803a6f7fbab871a0cce36487b863e9978ddea531cb37c0856c9739f4fe30", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_bengali_conformance.bin", b"CJCC", 1, "eb6ea6b3fa7df277ff1dbd5b23ab0d29154f6038d8093ec0d6d357e697c16d50", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_devanagari_conformance.bin", b"CJCD", 1, "be6f702916e84ebd071c1cc579f9d9f53033bc583a540fca69f91d58d88f0398", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_gujarati_conformance.bin", b"CJCE", 1, "04dd8a2d9d921598824a4dfc1c17aafed8d8d239dff0ac706a8b470bb7d672d2", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_gurmukhi_conformance.bin", b"CJCF", 1, "87a537e9384d442b1e864845358c62456051f79c63b6d6880d03f819f85ef445", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_kannada_conformance.bin", b"CJCG", 1, "6e2cc7ee72dfd2f060994b77fc72160f2cf8755caf85a57aae38326a362e4d8a", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_latin_conformance.bin", b"CJCI", 1, "a2f9a7427c28ed097d2f0042ef5c8f312167bcdf2fea0b457607856836effe96", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_oriya_conformance.bin", b"CJCJ", 1, "758d4b578b8d54e76b96d1581b6ea9e6f16b1a4dee2a9ec2e93ed2629a52d6ee", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_tamil_conformance.bin", b"CJCK", 1, "3762eb010aca054174325a78248aaef6cd067398f34d607aa9ebcca9aae38164", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_telugu_conformance.bin", b"CJCM", 1, "2d15e9a5b529099d70cab63d6062d7304c2b3d5e01ebb712b0a92990c2adcd79", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_bengali_conformance.bin", b"CJCP", 1, "5ac0852d6172727c71b130099caa1800c9781e89d437cd9432ac394bff157621", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_devanagari_conformance.bin", b"CJCQ", 1, "1fdadcddd10f40e4f97b1f50bee2f1710901b917031c17bc98c6b5da9a219e32", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_gujarati_conformance.bin", b"CJCR", 1, "13164d48039de60ffb839b559d891b1fc2bbea4ba7dd0c1915b6258dea2c22a8", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_gurmukhi_conformance.bin", b"CJCU", 1, "ed4389659a491f802bc8b2bc0dfba38d4a5102baa7d1332c761acbc12132736f", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_kannada_conformance.bin", b"CJCV", 1, "7738c36eafeb868385cee4215080446014cdca5937004bae9d6e0b79f1ba1c6f", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_latin_conformance.bin", b"CJCW", 1, "dae21b62329121569c6bcf2a8f6903e6da6f5094d8600bc5216ae83d50f03244", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_malayalam_conformance.bin", b"CJCX", 1, "49b30480b51b97510c6cf13a5c6933da11df032ed507d72ee97fc0f288cf9149", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_tamil_conformance.bin", b"CJCY", 1, "6d551b7ed8e2c180f76e764412aec16c2bfb5ce48c067160016359e11a304594", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_telugu_conformance.bin", b"CJCZ", 1, "a0bac32343dbd808fc121eee44d3ba6fa1744848da86c7a37ed2c2b1136cc940", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_bengali_conformance.bin", b"CJC4", 1, "dd6201b759dd7181e42a3d5ed7d526f021f2b74456789e7d12c0ea775c3d5df4", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_devanagari_conformance.bin", b"CJC5", 1, "5ef485347593a07cae2ac3a1de72ff100b95f7d193e9095d03bf7544cb751584", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_gujarati_conformance.bin", b"CJC6", 1, "4f1ea29f036e6bb9b49eb028e495e25a3614d980696e49cee88763164fe489fb", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_gurmukhi_conformance.bin", b"CJC7", 1, "f4d66cf348d90767ec2f88679cfbdb46e395535e2abcd977ed54c24574985e12", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_kannada_conformance.bin", b"CJC8", 1, "4031020a523eb565e9264c5be858eb6a0c53fd30431eeebb86e487efeb5ad970", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_latin_conformance.bin", b"CJC9", 1, "6eba870ab7e5b48cbe355f831a71c08d9a800ee04de9d25d6565718f45bf7918", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_malayalam_conformance.bin", b"CJDA", 1, "db12e300b9210ca01e82d699d4a420207b2a45e84c47923648a0bb96af2e6569", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_oriya_conformance.bin", b"CJDC", 1, "5d10779d207fee727b41f4560e21a468040956799471867caae425027928c26e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_telugu_conformance.bin", b"CJDD", 1, "f6e3a493bc0fa91a5a08f0ab306638c11537affb5cd051217031ea1b3f2b95fd", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_bengali_conformance.bin", b"CJDH", 1, "b023b9801037e32e74145c7bfe1d9f0b2c4b63ee13ed40275d8cb5db36424397", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_devanagari_conformance.bin", b"CJDJ", 1, "28fcbd8aaae09974367f8c4f55136c3f393c94cd42670e8222dfb951b0c22d23", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_gujarati_conformance.bin", b"CJDK", 1, "e49480aa655e7a03df6d41cf33a011ac58140bfdd1349667d11adc9c5fa252b9", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_gurmukhi_conformance.bin", b"CJDL", 1, "b27732f31ac35520b804d8e993a70f524309d979cbde37760ef5edf768808f63", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_kannada_conformance.bin", b"CJDM", 1, "3ef6d7c74c314f6c4dffad07d37916dcc36ccb69ceb55b56a6bcf5d14eb0cdaf", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_latin_conformance.bin", b"CJDN", 1, "e01f72dcf0cc68d2fecba13e622d76545c3a9e998c80fdccb66ce09d812565fa", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_malayalam_conformance.bin", b"CJDO", 1, "5c7f0742c6ef4c48a501950b15fe063c4a87acc1448b3532c0f9ffd941cf6597", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_oriya_conformance.bin", b"CJDP", 1, "bb8e06f685c3918da2db9a731282f7ee5645253cbf794acf7764b97e2fd303e5", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_tamil_conformance.bin", b"CJDQ", 1, "f233ae1073e8e384ecca4a0b7681fda3838fd1b264e2320d53443b60f00caecc", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_arabic_conformance.bin", b"CJAA", 1, "fd59c438a50f3a291e060caf76c305610978eec9d4345bece42d598f052dc751", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/bengali_ur_conformance.bin", b"CJAO", 1, "d6648c62d47bd282aefd9c425e93271eb209406a9c46f486cbb4b6a166b2f281", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_arabic_conformance.bin", b"CJAQ", 1, "deb361ca5b73661d6b0807a4ea788be101cbe435bdc24efd29208a5bfab8198a", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/devanagari_ur_conformance.bin", b"CJA5", 1, "506847c00cb34ed82f9ba59d44e60424d717ed6c3bddfdf956162c08c729d677", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_arabic_conformance.bin", b"CJA6", 1, "304a600414bb8fee9e4f09f681d0b733c52f5111a96737e7bb4bb72fe53decfe", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gujarati_ur_conformance.bin", b"CJBG", 1, "603a24a30a8786ced35ce08fbb44b01bee0e5958f4b508e8c41da94100cc0daf", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_arabic_conformance.bin", b"CJBH", 1, "43c4f29c8a493ac9a0a156d0922f0c39d2978672cba36d7179f80a152048f53e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/gurmukhi_ur_conformance.bin", b"CJBV", 1, "efc9055f3578120668e534632a5ab377422e2c4947cf4a0311da74030ce5c139", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_arabic_conformance.bin", b"CJBW", 1, "284789c1011f5ef13802619a8d81a5a78c116e0b86af22dbc5d848726abfe606", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/kannada_ur_conformance.bin", b"CJB9", 1, "8067f752c038bfe42cd4d61d0de7851a8474d908054b8bd0af277ad06c3ee9bd", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_arabic_conformance.bin", b"CJCB", 1, "daacfdc286b97da3e2ac37032a93206193e3ef976c2b2a2327a7b3d0b03a0157", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/malayalam_ur_conformance.bin", b"CJCN", 1, "d8f6f20dd8f60ae6237aa2fedd0c836bdc0d08994befccadcfb62fd2ddcdaf51", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_arabic_conformance.bin", b"CJCO", 1, "0501444fb3dbd0f5f7f46b0b9f0e7e3de867992f3ad22cd141959129c5a2c1ea", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/oriya_ur_conformance.bin", b"CJC0", 1, "f7f8b12eea1d7ccbb147afa74998834dbc2518703698845de225d990e0e3ba53", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_arabic_conformance.bin", b"CJC3", 1, "1cedf925d7c8f69f146a3195c59f100cb320c3e0e633094126f03e54872b7e3c", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/tamil_ur_conformance.bin", b"CJDF", 1, "6289e9c27907a79e9ee729c0f210db60c6a8d21896cd4fc0bd44e62eab79756e", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_arabic_conformance.bin", b"CJDG", 1, "dce58cea290af755ac76ae37a0fbb9b2cf23d508e47de3083771dfcf7b1dfeab", version=(48, 0, 0)),
    Blob("src/unicode/transliterate/telugu_ur_conformance.bin", b"CJDR", 1, "6f0377306c9ccd3f3489f7c93553e83b52a8dfab53ad6c4e5273bb609537854f", version=(48, 0, 0)),
)

GENERATORS = {
    "tools/generate_canonical_combining_class.py": "b8064fb61377c6bca1604c2bd35c6a1db37be5187762c7419ec90b4b19527b82",
    "tools/generate_canonical_decomposition.py": "fd4e57c7fd6e96af04082f591a193371bd97e1e8856152072d3e434ea8c0813d",
    "tools/generate_nonspacing_marks.py": "12d45f34ce2891ccf1b342bc8f44c6fe32e15e019d7a41489d8036dee9f8555c",
    "tools/unicode/normalization/generate_conformance.py": "c3e9f80b8fb410a2d142cfbb228941d01322672b28261c1e0c0de53eb662ee43",
    "tools/unicode/normalization/generate_data.py": "8ff9437a02bedd3048552a06c46e12377e626242e8f0146abaa400933742cd86",
    "tools/unicode/case/generate_data.py": "c4b275209f5fa8695b35c22ddd5cb95d2e08f40f35868b901dc22b39726a4dc9",
    "tools/unicode/case/generate_full_data.py": "ac0b2ce2938d19da1c8b80289fcfbbcb0e7176a95736ca3cf0d6b0b9631a9ed8",
    "tools/unicode/collation/generate_data.py": "3e789930a4ee07357d7e89a26d9bf93fe598ce7555efdbd16c524e860f0e4c96",
    "tools/unicode/collation/generate_tailorings.py": "bf1729359668f35ba580e4ca963c4221e2c61b57b68e61ab8d1c33f365bad5f2",
    "tools/unicode/collation/generate_conformance.py": "70766ae8612ebcbe1299897ae24c928f1e39ffbe2c5f10ab5f6cff96c28480e3",
    "tools/unicode/properties/generate_data.py": "2e55cb0f2aeae0367602e87ece0b8f8093fee1a18dacf38028ac732247874cb7",
    "tools/unicode/bidi/generate_conformance.py": "1ca3d3fd9fe5962f37192eb77d9aadfab6e5f9c670540a7ae691213682bb0425",
    "tools/unicode/bidi/generate_data.py": "ab6f9359af0f5d198b52d174041e35ffde11b0f8277a4bf5a8981a76c0a1cb05",
    "tools/unicode/grapheme/generate_conformance.py": "93378e8fcf4b0bd91630716a5378902cb3a1a41253b2d4fc4cd4688a036a3018",
    "tools/unicode/grapheme/generate_data.py": "b81dbba706482fa1c2ee562b42ff0a0a02e7dbc92095a8f79be2c01c1e9082c5",
    "tools/unicode/joining/generate_data.py": "625d8b9967340e795b683ec29815ae0c55f39f65cb8c883cda5e5a1d70bf85ba",
    "tools/unicode/idna/generate_data.py": "1bb79a63d0b5e7845c362e39a51b5a763b6afaa921fdf5e054c20f3920cdc34f",
    "tools/unicode/format/generate_plurals.py": "b1fd98acc793d8264d7cf8bb5a44335d8513ab1ba4321cac86fac7864ab5714b",
    "tools/unicode/format/generate_ordinals.py": "c67e49523dcfd86f641949774e2dae40ce8381828ca263fb61d5e487e406a91b",
    "tools/unicode/format/generate_numbers.py": "993871689fe126a56b60cfd98d7d3f1cff2879bc59afad5bc8becebfd3f7c8a8",
    "tools/unicode/format/generate_dates.py": "de6d58352b8793fee777752b980d27561e6ca400cb4710b95c9fda9b54999e45",
    "tools/unicode/format/generate_misc.py": "35d08acef5a6b7c23bbbe3b13977a2085f02df3985185068a68fe59e0625b0e1",
    "tools/unicode/charset/generate_data.py": "4c0c5da6fc12a091083e942607aa76c578e649c5c9bf121ad7a17114613fcb59",
    "tools/unicode/transliterate/generate_data.py": "f78f1992b4d9c044d63dd0440f8970ee3a33e8f46735f823d18cbc276ccc364f",
    "tools/unicode/break/generate_dictionaries.py": "bdbd4c4e9c999b4cea6a8924b08c72a49719c857e26dea82fc50940ee145e264",
    "tools/unicode/break/generate_word_conformance.py": "3c2467ffc38b2467cbbc0d895e76b8862774c48567aa3ad26b9681605df3a5ff",
    "tools/unicode/transliterate/generate_icu_conformance.py": "c1f2435db3039a3f569de277eccf5901a7c2ba34d396026be0815f39cd6dc997",
    "tools/unicode/name/generate_data.py": "bb3a64ad8a8c8fd2e34807cb10d81c76677f5e29c073c4808d75d48f234c9302",
    "tools/unicode/line_break/generate_conformance.py": "44b205d1b640cdb52e4316d649c584c97c2c94644437291fa568fbec1a2cd630",
    "tools/unicode/line_break/generate_data.py": "fa3d55066a98356ffcbf7abc50955a94e0c0f9eeec15758357bd14b8fcf55ac1",
    "tools/unicode/script/generate_data.py": "ce4168570f34cfa6d77b5f33bcf99a3cbc1f745639cda9878cfcc43407e2b6ab",
    "tools/unicode/script_extensions/generate_data.py": "20c00dac98c808300f286634a4d89f5eccd0d45db26aebf15d2d07b3089f17cb",
    "tools/unicode/sentence/generate_conformance.py": "038720b9002dbd73cdfb069dad112e86d64499c4c277c1250c77f9a0b9843dce",
    "tools/unicode/sentence/generate_data.py": "8e681662596e60b808ea36468c54f076c84112dcb8bee6c4c00bf3fe69c17a6e",
    "tools/unicode/vertical/generate_data.py": "be44ad521348fd3614f02f7ad3f58af1fdd3e72f9e27eeb6442bf4fb78a3df5b",
    "tools/unicode/word/generate_conformance.py": "5f86dd6601da9a8a9ca7418c84176eda90f76ea78970986cbc46272ca790c92b",
    "tools/unicode/word/generate_data.py": "a9ca3a51bdd7900c56393f22f6cc9d0730256eb6c43d648908f7b5da03013482",
}

GENERATED_TEXT = (
    GeneratedText(
        "src/unicode/canonical/combining_class.zig",
        "tools/generate_canonical_combining_class.py",
        "ca2e720d0fc25b5ce557d23c51fdfb2c5d729b2fe0ea34572ced577065d8dd6a",
    ),
    GeneratedText(
        "src/unicode/canonical/decomposition.zig",
        "tools/generate_canonical_decomposition.py",
        "5489909ff9ef7eaf0ef16a605f336abf1808f5b9338ef1eb6a0c44cda1b83f84",
    ),
    GeneratedText(
        "src/unicode/mark/nonspacing.zig",
        "tools/generate_nonspacing_marks.py",
        "5c347a415ea883455e41e76121b95cd711da5af731144d8257d2bd3ddc9ff013",
    ),
    GeneratedText(
        "src/unicode/normalization/data.zig",
        "tools/unicode/normalization/generate_data.py",
        "a5bcfb68fcc7d82e8f90db62ba529315f587a57eeafe4cd46576d98ef7720d48",
    ),
    GeneratedText(
        "src/unicode/name/ranges.zig",
        "tools/unicode/name/generate_data.py",
        "8ba682d5f518463e1f0d7040ad158fa04b4b8aa17d992ec2be8b1a3b1c019695",
    ),
    GeneratedText(
        "src/unicode/case/data.zig",
        "tools/unicode/case/generate_data.py",
        "00e78d46e6526c56d39fb374de74a552d4968808273c635a56cffbd134e07ae8",
    ),
    GeneratedText(
        "src/unicode/case/full_data.zig",
        "tools/unicode/case/generate_full_data.py",
        "4409a03ce50d8cac29a4d7aa724a47e9e465223d39cf3ad79eead7cdbf0b8dc5",
    ),
    GeneratedText(
        "src/unicode/collation/implicit.zig",
        "tools/unicode/collation/generate_data.py",
        "3f97d33d128a96ad6be967674dde1115df8b6a2b2632a2f9f5e55729a3d9b899",
    ),
    GeneratedText(
        "src/unicode/format/plurals_data.zig",
        "tools/unicode/format/generate_plurals.py",
        "c958d5772ba439b2871401c7526b434b566c5603a74dcbc6adb1e1ea30abc754",
    ),
    GeneratedText(
        "src/unicode/format/ordinals_data.zig",
        "tools/unicode/format/generate_ordinals.py",
        "49488208bb9e2dcd2f5d1afdca602a914c2e6d3bb7769b680928ec950670f6c2",
    ),
    GeneratedText(
        "src/unicode/format/numbers_data.zig",
        "tools/unicode/format/generate_numbers.py",
        "351f2446d91fb8d7dd3fbd8ac86969de42a2953702b4170e59d2819b1d31b9c9",
    ),
    GeneratedText(
        "src/unicode/format/dates_data.zig",
        "tools/unicode/format/generate_dates.py",
        "d2fb836e0410f5068c501d81708c22aef485e42fcfd625adb8cce193f194b6ce",
    ),
    GeneratedText(
        "src/unicode/format/list_data.zig",
        "tools/unicode/format/generate_misc.py",
        "0aa642a85cd89aeabee5916a49dc9c3895ee7f23729bdb9201cef26e87e6e9c8",
    ),
    GeneratedText(
        "src/unicode/format/relative_data.zig",
        "tools/unicode/format/generate_misc.py",
        "08b6d522b1f8c56e82734b0b02ea076a85ba711c33c2de8a8019d524fc8eccd6",
    ),
    GeneratedText(
        "src/unicode/format/units_data.zig",
        "tools/unicode/format/generate_misc.py",
        "5a08f64bf5eca2ef85cf494904b61116f4a9a71e1a165e7b5739e43eb60ed0b2",
    ),
    GeneratedText(
        "src/unicode/format/currencies_data.zig",
        "tools/unicode/format/generate_misc.py",
        "9db9bb3298bea10b6978b3ca5684cbbd1daa0024c1004b11370a20f93e9f42de",
    ),
    GeneratedText(
        "src/unicode/properties/general_category.zig",
        "tools/unicode/properties/generate_data.py",
        "d294db0173d16d80a536b4370bd4a04726d3960b754169c7d432f97b2e0eb3f6",
    ),
    GeneratedText(
        "src/unicode/properties/aliases.zig",
        "tools/unicode/properties/generate_data.py",
        "464383d7f965624e98b023c0dd7c4805e651e34a14fc2f87268a1faf8ad960a4",
    ),
    GeneratedText(
        "src/unicode/vertical/data.zig",
        "tools/unicode/vertical/generate_data.py",
        "c38118ef695568864af362387684b6333336a082aec5ca4f6814faac7f35ee8d",
    ),
)
SOURCE_SHA = re.compile(r"^// Source SHA-256: ([0-9a-f]{64})$", re.MULTILINE)


def digest(path: Path, *, text: bool = False) -> str:
    data = path.read_bytes()
    if text:
        # Git may materialize text files with CRLF on Windows. Hash canonical
        # LF bytes so checkout policy cannot make verified sources look stale.
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return hashlib.sha256(data).hexdigest()


def check_page_table(data: bytes, width: int) -> None:
    index_count, page_count = struct.unpack_from("<HH", data, 8)
    assert index_count == 0x1100
    assert 12 + index_count * 2 + page_count * 256 * width == len(data)


def check_layout(blob: Blob, data: bytes) -> None:
    magic = blob.magic
    if magic == b"CJDB":
        language_count = data[5]
        offset = 8 + language_count * 12
        for index in range(language_count):
            node_count, edge_count, _, _ = struct.unpack_from(
                "<IIHH", data, 8 + index * 12
            )
            offset += node_count * 8 + edge_count * 4
        assert offset == len(data)
    elif magic == b"CJDW":
        case_count = struct.unpack_from("<I", data, 8)[0]
        offset = 12
        for _ in range(case_count):
            source_len, segment_count = struct.unpack_from("<HH", data, offset)
            offset += 4 + source_len + segment_count * 2
        assert offset == len(data)
    elif magic in (b"CJGB", b"CJWB", b"CJSB", b"CJC1", b"CJQ1"):
        check_page_table(data, 1)
    elif magic == b"CJP2":
        index_count, page_count = struct.unpack_from("<HH", data, 8)
        assert index_count == 0x1100
        assert 16 + index_count * 2 + page_count * 256 * 8 == len(data)
    elif magic == b"CJID":
        index_count, page_count, mapping_count, pool_count = struct.unpack_from(
            "<HHII", data, 8
        )
        assert index_count == 0x1100
        assert (
            20
            + index_count * 2
            + page_count * 256
            + mapping_count * 10
            + pool_count * 4
            == len(data)
        )
    elif magic == b"CJTR":
        (
            transform_count,
            _,
            entry_count,
            source_count,
            target_count,
            set_count,
            range_count,
            context_count,
            context_element_count,
        ) = struct.unpack_from("<BB7I", data, 8)
        step_count = struct.unpack_from("<I", data, 40)[0]
        names_length = 0
        for index in range(transform_count):
            (
                name_offset,
                name_len,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
            ) = struct.unpack_from(
                "<HBBIIBBIBBIIIHH", data, 44 + index * 36
            )
            names_length = max(names_length, name_offset + name_len)
        assert (
            44
            + transform_count * 36
            + step_count * 8
            + entry_count * 20
            + set_count * 8
            + range_count * 8
            + context_count * 8
            + context_element_count * 8
            + names_length
            + source_count * 4
            + target_count * 4
            == len(data)
        )
    elif magic in (b"CJA0", b"CJA1", b"CJA2", b"CJA3", b"CJA4", b"CJA5", b"CJA6", b"CJA7", b"CJA8", b"CJA9", b"CJAA", b"CJAB", b"CJAC", b"CJAD", b"CJAE", b"CJAF", b"CJAG", b"CJAH", b"CJAI", b"CJAJ", b"CJAK", b"CJAL", b"CJAM", b"CJAN", b"CJAO", b"CJAP", b"CJAQ", b"CJAR", b"CJAS", b"CJAT", b"CJAU", b"CJAV", b"CJAW", b"CJAX", b"CJAY", b"CJAZ", b"CJB0", b"CJB2", b"CJB3", b"CJB4", b"CJB5", b"CJB6", b"CJB7", b"CJB8", b"CJB9", b"CJBA", b"CJBB", b"CJBC", b"CJBD", b"CJBE", b"CJBF", b"CJBG", b"CJBH", b"CJBI", b"CJBJ", b"CJBK", b"CJBL", b"CJBM", b"CJBN", b"CJBO", b"CJBP", b"CJBQ", b"CJBR", b"CJBS", b"CJBU", b"CJBV", b"CJBW", b"CJBX", b"CJBY", b"CJBZ", b"CJC0", b"CJC2", b"CJC3", b"CJC4", b"CJC5", b"CJC6", b"CJC7", b"CJC8", b"CJC9", b"CJCA", b"CJCB", b"CJCC", b"CJCD", b"CJCE", b"CJCF", b"CJCG", b"CJCH", b"CJCI", b"CJCJ", b"CJCK", b"CJCM", b"CJCN", b"CJCO", b"CJCP", b"CJCQ", b"CJCR", b"CJCU", b"CJCV", b"CJCW", b"CJCX", b"CJCY", b"CJCZ", b"CJD2", b"CJD3", b"CJDA", b"CJDC", b"CJDD", b"CJDE", b"CJDF", b"CJDG", b"CJDH", b"CJDI", b"CJDJ", b"CJDK", b"CJDL", b"CJDM", b"CJDN", b"CJDO", b"CJDP", b"CJDQ", b"CJDR", b"CJE3", b"CJE4", b"CJE5", b"CJE6", b"CJE7", b"CJEF", b"CJEG", b"CJEI", b"CJEL", b"CJEU", b"CJFA", b"CJFW", b"CJG3", b"CJGE", b"CJGG", b"CJGI", b"CJGR", b"CJH3", b"CJHA", b"CJHF", b"CJHK", b"CJHW", b"CJIA", b"CJIB", b"CJIE", b"CJIG", b"CJIK", b"CJIM", b"CJIO", b"CJIU", b"CJIX", b"CJK3", b"CJKA", b"CJKH", b"CJKI", b"CJKK", b"CJKO", b"CJKZ", b"CJLA", b"CJLC", b"CJLI", b"CJLL", b"CJLQ", b"CJLS", b"CJLU", b"CJM3", b"CJMC", b"CJMF", b"CJMI", b"CJMO", b"CJN2", b"CJNK", b"CJOF", b"CJP3", b"CJPA", b"CJPB", b"CJPE", b"CJPM", b"CJPR", b"CJPS", b"CJPX", b"CJPZ", b"CJRI", b"CJRS", b"CJRU", b"CJSF", b"CJSG", b"CJSL", b"CJSY", b"CJT2", b"CJTA", b"CJTG", b"CJTH", b"CJTI", b"CJTM", b"CJTN", b"CJTT", b"CJTU", b"CJUA", b"CJUI", b"CJVF", b"CJYL", b"CJZ1", b"CJZ2", b"CJZ3", b"CJZ4", b"CJZU"):
        case_count = struct.unpack_from("<I", data, 8)[0]
        offset = 12
        for _ in range(case_count):
            source_len, target_len = struct.unpack_from("<HH", data, offset)
            offset += 4 + source_len + target_len
        assert offset == len(data)
    elif magic == b"CJCS":
        section_count = struct.unpack_from("<H", data, 8)[0]
        end = 12 + section_count * 12
        for index in range(section_count):
            _, _, offset, length = struct.unpack_from(
                "<HHII", data, 12 + index * 12
            )
            assert offset >= end
            assert offset + length <= len(data)
            end = max(end, offset + length)
        assert end == len(data)
    elif magic == b"CJTL":
        locale_count, rule_count, ce_count, names_length, codepoint_count = (
            struct.unpack_from("<HIIII", data, 8)
        )
        reorder_offset = (
            28
            + locale_count * 16
            + rule_count * 12
            + names_length
            + codepoint_count * 4
            + ce_count * 16
        )
        group_count, _, _, map_count = struct.unpack_from(
            "<HHHH", data, reorder_offset
        )
        assert (
            reorder_offset
            + 12
            + group_count * 8
            + map_count * (4 + group_count * 4)
            == len(data)
        )
    elif magic == b"CJPL":
        case_count = struct.unpack_from("<I", data, 8)[0]
        offset = 12
        for _ in range(case_count):
            locale_len = data[offset]
            text_len = struct.unpack_from("<H", data, offset + 3)[0]
            offset += 5 + locale_len + text_len
        assert offset == len(data)
    elif magic == b"CJIT":
        case_count = struct.unpack_from("<I", data, 8)[0]
        offset = 12
        for _ in range(case_count):
            source_len, unicode_len, ascii_len, ascii_t_len = struct.unpack_from(
                "<HHHH", data, offset
            )
            offset += 9 + source_len + unicode_len + ascii_len + ascii_t_len
        assert offset == len(data)
    elif magic == b"CJJ1":
        index_count, page_count = struct.unpack_from("<HH", data, 8)
        assert index_count == 0x1100
        assert 16 + index_count * 2 + page_count * 256 == len(data)
    elif magic == b"CJNM":
        record_count, pool_len = struct.unpack_from("<II", data, 8)
        assert 16 + record_count * 12 + pool_len == len(data)
    elif magic == b"CJCL":
        index_count, page_count, entry_count, ce_count = struct.unpack_from(
            "<HHII", data, 8
        )
        assert index_count == 0x1100
        assert (
            20
            + index_count * 2
            + page_count * 256 * 2
            + entry_count * 20
            + ce_count * 16
            == len(data)
        )
    elif magic == b"CJCT":
        case_count = struct.unpack_from("<I", data, 8)[0]
        offset = 12
        for _ in range(case_count):
            length = data[offset]
            offset += 1 + length * 4
        assert offset == len(data)
    elif magic == b"CJL2":
        check_page_table(data, 2)
    elif magic == b"CJS1":
        index_count, page_count = struct.unpack_from("<HH", data, 12)
        assert index_count == 0x1100
        assert 16 + index_count * 2 + page_count * 256 == len(data)
    elif magic == b"CJB1":
        index_count, page_count, brackets, mirrors = struct.unpack_from("<HHHH", data, 8)
        assert index_count == 0x1100
        assert 16 + index_count * 2 + page_count * 256 + brackets * 12 + mirrors * 8 == len(data)
    elif magic == b"CJSE":
        set_count, member_count, entry_count = struct.unpack_from("<HHI", data, 12)
        assert 20 + (set_count + 1) * 2 + member_count + entry_count * 8 == len(data)
    else:
        assert len(data) >= (20 if magic == b"CJBT" else 12)


def main() -> None:
    for blob in BLOBS:
        path = ROOT / blob.path
        data = path.read_bytes()
        if len(data) < 8 or data[:4] != blob.magic:
            raise SystemExit(f"{blob.path}: invalid magic")
        if data[4] != blob.format_version or tuple(data[5:8]) != blob.version:
            raise SystemExit(f"{blob.path}: invalid format/Unicode version")
        try:
            check_layout(blob, data)
        except (AssertionError, struct.error):
            raise SystemExit(f"{blob.path}: invalid committed layout") from None
        if digest(path) != blob.sha256:
            raise SystemExit(f"{blob.path}: SHA-256 changed; regenerate and review it")

    for relative, expected in GENERATORS.items():
        if digest(ROOT / relative, text=True) != expected:
            raise SystemExit(f"{relative}: generator changed without reviewed artifacts")

    for generated in GENERATED_TEXT:
        if generated.generator not in GENERATORS:
            raise SystemExit(
                f"{generated.path}: unpinned generator {generated.generator}"
            )
        path = ROOT / generated.path
        if digest(path, text=True) != generated.sha256:
            raise SystemExit(f"{generated.path}: committed generated output changed")
        first_line = path.read_text(encoding="utf-8").splitlines()[0]
        if generated.generator not in first_line:
            raise SystemExit(
                f"{generated.path}: missing {generated.generator} provenance"
            )

    vertical = ROOT / "src/unicode/vertical/data.zig"
    text = vertical.read_text(encoding="utf-8")
    match = SOURCE_SHA.search(text)
    # The digest is provenance for the unavailable UCD input; its presence is
    # required, while reproducibility is covered when that input is supplied.
    if match is None:
        raise SystemExit("vertical/data.zig: missing source SHA-256 provenance")

    print(
        f"verified {len(BLOBS)} Unicode blobs, {len(GENERATED_TEXT)} "
        f"generated sources, and {len(GENERATORS)} generators"
    )


if __name__ == "__main__":
    main()
