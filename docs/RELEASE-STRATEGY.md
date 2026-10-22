# Release Strategy: Multi-repo + Repo กลาง (GitOps)

2026-10-22 · mart

ต้นฉบับ: [Claude Docs](https://claude.ai/artifact/7PMxD9WHJFSWz72kxcviFt) (คัดลอกมาเก็บไว้ใน repo นี้ ส่วน "สิ่งที่ POC นี้ทำต่างจากเอกสาร" อยู่ท้ายไฟล์)

## ภาพรวมและหลักการ

แต่ละ app repo (be, fe, mobile) มีหน้าที่ build และ tag version เท่านั้น ส่วน repo กลาง `deploy` เป็นที่เดียวที่บอกว่า staging กับ prod รัน version อะไร การ deploy ทุกครั้งจึงเกิดจาก commit ใน repo กลาง

หลักการที่ทุกคนต้องยึด:

- **Build once, deploy many**: build artifact ครั้งเดียวตอน tag rc แล้ว promote ตัวเดิมขึ้น prod ห้าม build ใหม่
- **Prod = ของที่ผ่าน staging แล้วเท่านั้น**: version ที่ขึ้น prod ต้องเคยมี rc บน commit เดียวกัน
- **Version แยกกันอิสระต่อ app**: be 3.2.0 กับ fe 2.1.0 ไม่ต้องเลขตรงกัน
- **BE backward compatible เสมอ**: เพราะ mobile เวอร์ชันเก่ายังอยู่ในมือ user
- **ลำดับ deploy**: BE ก่อน → FE → Mobile

## โครงสร้าง repo

be และ fe ไม่ deploy เอง แต่อัปเดตไฟล์ใน repo กลาง (rc เขียน staging ตรง, final เปิด PR แก้ prod) ส่วน mobile ส่ง store ตรงและบันทึก version ลง repo กลางไว้ดูอย่างเดียว

```yaml
# deploy/prod/versions.yaml
be:     3.1.4
fe:     2.0.7
mobile: 3.1.0   # อ้างอิงเท่านั้น
```

## กฎ versioning และ tag

ใช้ SemVer แยกต่อ repo โดย staging ใช้ `-rc.N` และ prod ใช้เลขเต็มที่ชี้ commit เดียวกับ rc ตัวสุดท้าย

| Tag | ความหมาย | ผล |
| --- | --- | --- |
| `v3.2.0-rc.1`, `rc.2`, … | รอบทดสอบของ phase 3.2.0 | build แล้วอัปเดต `staging/versions.yaml` |
| `v3.2.0` | rc ตัวที่ผ่าน test | เปิด PR อัปเดต `prod/versions.yaml` |
| `v3.2.1` | hotfix หลัง 3.2.0 ขึ้น prod แล้ว | ผ่าน staging สั้นๆ แล้วขึ้น prod |
| `v3.3.0-rc.1` | เริ่ม phase ถัดไป | ขึ้น staging |

ข้อห้าม:

- ห้ามใช้ `3.2.1`, `3.2.2` เป็นรอบ staging เพราะเลข patch สงวนไว้สำหรับ hotfix หลังขึ้น prod
- ห้าม tag prod บน commit ที่ไม่เคยมี rc (CI จะ fail ให้)
- ห้ามลบหรือย้าย tag ที่ push ไปแล้ว ถ้าพลาดให้ออกเลขใหม่

เนื่องจากแยก repo แล้ว tag ไม่ต้องมี prefix `be/` `fe/` (prefix ใช้เฉพาะ monorepo)

## Flow ขึ้น staging

ขึ้น staging ด้วยการ tag rc ใน app repo แล้ว CI ทำที่เหลือให้อัตโนมัติ ไม่ต้องมีคน approve

1. ทำ feature บน `feature/xxx` แล้วเปิด PR เข้า `main` (CI: lint, test, build check)
2. Merge เข้า `main`
3. Tag rc บน commit ที่ต้องการ เช่น `git tag -a v3.2.0-rc.1 -m "rc.1"` แล้ว `git push origin v3.2.0-rc.1` (หรือสร้างผ่าน GitHub Releases ติ๊ก pre-release)
4. CI ของ app repo build image แล้ว push เข้า registry ในชื่อ `3.2.0-rc.1`
5. CI เดียวกัน commit ตรงเข้า `deploy` repo แก้ `staging/versions.yaml` เป็น `be: 3.2.0-rc.1`
6. Workflow ใน `deploy` repo เห็นไฟล์เปลี่ยน แล้ว deploy staging
7. QA test ถ้าเจอบั๊กหรือเพิ่ม feature ก็วนกลับข้อ 1 แล้ว tag `rc.2`, `rc.3` ไปเรื่อยๆ

## Flow ขึ้น prod

ขึ้น prod ด้วย tag เลขเต็มบน commit เดียวกับ rc ที่ผ่าน แล้ว merge PR ใน repo กลางซึ่งต้องมีคน approve

1. เลือก rc ที่ test ผ่าน เช่น `v3.2.0-rc.3`
2. Tag เลขเต็มบน commit เดียวกัน: `git tag -a v3.2.0 v3.2.0-rc.3^{} -m "3.2.0"` แล้ว `git push origin v3.2.0` (ถ้า HEAD ของ main คือ commit เดียวกับ rc.3 ก็ tag จาก main ได้เลย)
3. CI เช็กว่า commit นี้มี rc tag ถ้าไม่มีให้ fail
4. CI retag image ตัวเดิม `3.2.0-rc.3` เป็น `3.2.0` (ไม่ build ใหม่)
5. CI เปิด PR ใน `deploy` repo แก้ `prod/versions.yaml` เป็น `be: 3.2.0`
6. Tech lead review และ approve PR ถ้าต้องขึ้นพร้อมกันหลาย app ให้รวม version ไว้ใน PR เดียว
7. Merge แล้ว workflow ใน `deploy` repo deploy prod ตามลำดับ BE → FE

## Hotfix และ rollback

Rollback คือการ revert commit ใน `deploy` repo ส่วน hotfix คือออก patch version ใหม่ผ่าน flow เดิมแบบย่อ

**Rollback (เร็วที่สุด)**: เปิด PR revert commit ล่าสุดใน `prod/versions.yaml` เช่น 3.2.0 → 3.1.4 แล้ว merge ระบบจะ deploy image เก่ากลับไป ต้องระวัง DB migration ที่ไม่ backward compatible

**Hotfix กรณี main พร้อมปล่อย**: แก้บน main → tag `v3.2.1-rc.1` → test บน staging → tag `v3.2.1` → PR ใน repo กลาง

**Hotfix กรณี main มีของ phase ถัดไปค้างอยู่**:

1. `git checkout -b hotfix/3.2.1 v3.2.0`
2. แก้บั๊ก แล้ว tag `v3.2.1-rc.1` จาก branch นี้
3. Test ผ่านแล้ว tag `v3.2.1` และขึ้น prod ตามปกติ
4. เปิด PR เอา fix กลับเข้า `main` ทันที (ห้ามลืม)

## Mobile

Mobile ใช้กฎ tag เดียวกัน แต่ deploy ผ่าน store ไม่ใช่ผ่าน repo กลาง และ rollback ไม่ได้

| Tag | ผล |
| --- | --- |
| `v3.2.0-rc.N` | build ส่ง TestFlight internal และ Play internal track |
| `v3.2.0` | promote build ของ rc ที่ผ่านไป production แล้ว submit review |

- Store เห็น version `3.2.0` เสมอ ส่วน build number ใช้ `github.run_number` ที่เพิ่มขึ้นเรื่อยๆ
- บันทึก version ลง `versions.yaml` เพื่อให้ดูที่เดียวรู้ครบทุก app (ไม่ได้ใช้ deploy)
- ขึ้น BE ที่รองรับ feature ใหม่บน prod ก่อน submit แอปเสมอ
- มี force-update endpoint ไว้บังคับอัปเดตกรณีฉุกเฉิน
- ถ้าต้อง stabilize ระหว่างรอ review ให้ตัด `release/3.2` แล้ว tag rc จาก branch นั้น เสร็จแล้ว cherry-pick fix กลับ main
- ถ้าใช้ React Native/Expo แก้บั๊กที่เป็น JS อย่างเดียวผ่าน EAS Update ได้โดยไม่ต้องรอ store

## Checklist การ setup

- [ ] สร้าง `deploy` repo พร้อม `staging/versions.yaml` และ `prod/versions.yaml`
- [ ] เขียน `scripts/deploy.sh` ที่อ่าน versions.yaml แล้ว deploy ตามลำดับ BE → FE
- [ ] ตั้ง GitHub Environment `production` ใน `deploy` repo ให้มี required reviewers และเก็บ secrets ของ prod ไว้ที่นี่เท่านั้น
- [ ] Branch protection บน `main` ของ `deploy` repo ต้องผ่าน PR และ review (ยกเว้น bot ให้ push `staging/` ตรงได้)
- [ ] สร้าง GitHub App หรือ fine-grained PAT แล้วเก็บเป็น `DEPLOY_REPO_TOKEN` ใน app repo ทุกตัว
- [ ] ใส่ `release.yml` ใน be และ fe (ควรย้ายเป็น reusable workflow ใน repo กลางเมื่อตั้งตัวแล้ว)
- [ ] ตั้ง tag protection ให้ `v*` สร้างได้เฉพาะ maintainer
- [ ] ตั้ง pipeline mobile: rc → TestFlight/Play internal, final → promote production
- [ ] ทำ force-update endpoint ใน BE
- [ ] ซ้อม rollback จริงบน staging หนึ่งครั้งก่อนใช้กับ prod

## สิ่งที่ POC นี้ทำต่างจากเอกสาร

| เรื่อง | ใน POC |
| --- | --- |
| ชื่อ tag | คนสร้างในหน้า Releases เป็น `staging/vX.Y.Z` (รอบทดสอบซ้ำของเลขเดิม: `staging/vX.Y.Z-2`) และ `prod/vX.Y.Z` แทน `vX.Y.Z-rc.N` / `vX.Y.Z` กฎยังเหมือนเดิม: prod ต้องมี staging ของเลขเดียวกันบน commit เดียวกัน |
| ชื่อ repo กลาง | `ff-poc-hub` (เอกสารเรียก `deploy`) app repo คือ `ff-poc-be` และ `ff-poc-fe` (เว็บ + แอป Capacitor อยู่ repo เดียวกัน) |
| ส่วนที่อัปเดต hub | ย้ายเป็น reusable workflow `.github/workflows/promote.yml` ใน hub แล้ว app repo เรียกใช้ตัวเดียวกัน |
| FE build ครั้งเดียว | FE อ่าน `config.json` ตอนเปิดแอป hub ใส่ `config/<stage>.json` ตอน deploy จึงใช้ web build ตัวเดียวกันได้ทั้ง staging และ prod |
| BE deploy | จำลอง: pull image จาก GHCR แล้วรันบน runner ตรวจ `/health` และ `/version` |
| FE deploy | GitHub Pages ของ hub: `/staging/` และ `/prod/` |
| ตัวกั้น prod | merge PR ใน hub + approve environment `production` (PR ไม่บังคับ approve เพราะคนเปิด PR กับคนรีวิวเป็นคนเดียวกันใน POC) |
